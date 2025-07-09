#!/bin/bash

# --- 脚本配置变量 ---
BACKUP_DIR="/media/8T/4Backups/Backup" # 备份镜像文件保存的目录
TMP_MOUNT_BASE="/tmp/rpi_backup_mount"  # 临时挂载基目录，避免用 /mnt 造成风险
MOUNT_BOOT="${TMP_MOUNT_BASE}/boot"
MOUNT_ROOT="${TMP_MOUNT_BASE}/root"

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本必须以 root 用户身份运行！请使用 sudo ./your_script_name.sh"
    exit 1
fi

# --- 安装所需软件 ---
echo "--- 阶段 1/8: 检查并安装所需软件 ---"
REQUIRED_PKGS="dosfstools parted kpartx rsync jq"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "正在安装 $pkg..."
        apt update && apt install -y "$pkg"
        if [ $? -ne 0 ]; then
            echo "错误：安装 $pkg 失败。请检查网络连接或 APT 源。"
            exit 1
        fi
    fi
done
echo "所有必要软件已准备就绪。"

# --- 定义清理函数 ---
cleanup() {
    echo "--- 执行清理操作 ---"
    # 解挂载临时挂载点，删除目录
    for mp in "$MOUNT_BOOT" "$MOUNT_ROOT"; do
        if mountpoint -q "$mp"; then
            umount "$mp"
            echo "卸载 $mp"
        fi
        if [ -d "$mp" ]; then
            rmdir "$mp" 2>/dev/null && echo "删除空目录 $mp"
        fi
    done
    # 删除基目录（如果空）
    if [ -d "$TMP_MOUNT_BASE" ]; then
        rmdir "$TMP_MOUNT_BASE" 2>/dev/null && echo "删除空目录 $TMP_MOUNT_BASE"
    fi

    # 解除循环设备映射
    if [ -n "$loopdevice" ] && losetup "$loopdevice" &>/dev/null; then
        kpartx -d "$loopdevice" &>/dev/null
        losetup -d "$loopdevice" &>/dev/null
        echo "已解除循环设备 $loopdevice 及其映射。"
    fi
    echo "清理完成。"
}
trap cleanup EXIT

# --- 准备备份目录 ---
echo "--- 阶段 2/8: 准备备份目录 ---"
mkdir -p "$BACKUP_DIR"
if [ $? -ne 0 ]; then
    echo "错误：无法创建备份目录 $BACKUP_DIR。请检查路径和权限。"
    exit 1
fi
echo "备份目录已确认/创建：$BACKUP_DIR"

# --- 获取系统盘设备 ---
echo "--- 阶段 3/8: 自动检测系统盘并获取信息 ---"
ROOT_DEVICE_PARTITION=$(df -P / | tail -n 1 | awk '{print $1}')
if [ -z "$ROOT_DEVICE_PARTITION" ]; then
    echo "错误：无法确定根目录 / 的挂载分区。退出。"
    exit 1
fi

# 解析设备名
if [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/nvme[0-9]n[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
else
    echo "错误：无法解析根目录所在设备的类型。退出。"
    exit 1
fi

echo "检测到系统盘设备为：$SD_DEVICE"

# 分区命名规则
if [[ "$SD_DEVICE" =~ ^/dev/mmcblk ]] || [[ "$SD_DEVICE" =~ ^/dev/nvme ]]; then
    BOOT_PART="${SD_DEVICE}p1"
    ROOT_PART="${SD_DEVICE}p2"
else
    BOOT_PART="${SD_DEVICE}1"
    ROOT_PART="${SD_DEVICE}2"
fi

if [ ! -b "$SD_DEVICE" ]; then
    echo "错误：系统盘设备 $SD_DEVICE 不存在。"
    exit 1
fi

# 读取分区信息
PART_INFO=$(lsblk -o NAME,PARTUUID,FSTYPE,MOUNTPOINTS,SIZE "${SD_DEVICE}" -J)
if [ $? -ne 0 ]; then
    echo "错误：无法获取设备 $SD_DEVICE 的分区信息。"
    exit 1
fi

BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r "
    .blockdevices[] | (.children[]? // .) |
    select(.name == \"$(basename "$BOOT_PART")\") | .mountpoints[0] // \"\"
")
ORIG_BOOT_PARTUUID=$(echo "$PART_INFO" | jq -r "
    .blockdevices[] | (.children[]? // .) |
    select(.name == \"$(basename "$BOOT_PART")\") | .partuuid // \"\"
")
ORIG_ROOT_PARTUUID=$(echo "$PART_INFO" | jq -r "
    .blockdevices[] | (.children[]? // .) |
    select(.name == \"$(basename "$ROOT_PART")\") | .partuuid // \"\"
")
BOOT_FSTYPE=$(echo "$PART_INFO" | jq -r "
    .blockdevices[] | (.children[]? // .) |
    select(.name == \"$(basename "$BOOT_PART")\") | .fstype // \"\"
")
ROOT_FSTYPE=$(echo "$PART_INFO" | jq -r "
    .blockdevices[] | (.children[]? // .) |
    select(.name == \"$(basename "$ROOT_PART")\") | .fstype // \"\"
")

if [ -z "$BOOT_MOUNTPOINT" ] || [ -z "$ORIG_BOOT_PARTUUID" ] || [ -z "$ORIG_ROOT_PARTUUID" ] || [ -z "$BOOT_FSTYPE" ] || [ -z "$ROOT_FSTYPE" ]; then
    echo "错误：未能获取完整系统盘分区信息，请检查。"
    exit 1
fi

# 估算镜像大小（根分区已用空间+引导分区总空间）*1.2
ROOT_USED_KB=$(df -P / | tail -n1 | awk '{print $3}')
BOOT_TOTAL_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -n1 | awk '{print $2}')
IMAGE_SIZE_KB=$(( (ROOT_USED_KB + BOOT_TOTAL_KB) * 12 / 10 ))

echo "系统盘设备: $SD_DEVICE"
echo "引导分区挂载点: $BOOT_MOUNTPOINT (PARTUUID: $ORIG_BOOT_PARTUUID)"
echo "根分区 PARTUUID: $ORIG_ROOT_PARTUUID"
echo "估算镜像大小: $((IMAGE_SIZE_KB / 1024)) MB"

read -p "请确认以上信息无误，即将创建系统盘备份镜像文件。(y/N): " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "备份已取消。"
    exit 0
fi

# --- 创建空镜像文件 ---
echo "--- 阶段 4/8: 创建空的镜像文件 ---"
IMAGE_FILE_NAME="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="${BACKUP_DIR}/${IMAGE_FILE_NAME}"

echo "正在创建镜像文件：$DEST_IMG_PATH (约 $((IMAGE_SIZE_KB / 1024)) MB)..."
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress
if [ $? -ne 0 ]; then
    echo "错误：创建镜像文件失败。"
    exit 1
fi

# --- 创建分区表 ---
echo "--- 阶段 5/8: 创建分区表 ---"
PARTED_INFO=$(fdisk -l "$SD_DEVICE")
BOOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $2}')
BOOT_END_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $3}')
ROOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${ROOT_PART}" | awk '{print $2}')

if [ -z "$BOOT_START_SECTOR" ] || [ -z "$BOOT_END_SECTOR" ] || [ -z "$ROOT_START_SECTOR" ]; then
    echo "错误：无法解析分区起始/结束扇区。"
    exit 1
fi

parted "$DEST_IMG_PATH" --script -- mklabel msdos
parted "$DEST_IMG_PATH" --script -- mkpart primary fat32 "${BOOT_START_SECTOR}s" "${BOOT_END_SECTOR}s"
parted "$DEST_IMG_PATH" --script -- mkpart primary ext4 "${ROOT_START_SECTOR}s" "100%"

echo "分区表创建完成。"

# --- 挂载镜像文件并格式化 ---
echo "--- 阶段 6/8: 挂载镜像并格式化 ---"
loopdevice=$(losetup -f --show "$DEST_IMG_PATH")
if [ -z "$loopdevice" ]; then
    echo "错误：挂载循环设备失败。"
    exit 1
fi

kpartx -va "$loopdevice"
sleep 2s

device_mapper_name=$(basename "$loopdevice")
partBoot="/dev/mapper/${device_mapper_name}p1"
partRoot="/dev/mapper/${device_mapper_name}p2"

if [ ! -b "$partBoot" ] || [ ! -b "$partRoot" ]; then
    echo "错误：映射分区不存在。"
    exit 1
fi

echo "格式化引导分区 $partBoot ..."
mkfs.vfat -F 32 -n boot "$partBoot"
echo "格式化根分区 $partRoot ..."
mkfs.ext4 -F "$partRoot"
e2label "$partRoot" rootfs

# --- 挂载镜像分区 ---
echo "--- 阶段 7/8: 挂载镜像分区 ---"
mkdir -p "$MOUNT_BOOT" "$MOUNT_ROOT"

mount -t "$BOOT_FSTYPE" "$partBoot" "$MOUNT_BOOT"
if ! mountpoint -q "$MOUNT_BOOT"; then
    echo "错误：引导分区挂载失败。"
    exit 1
fi

mount -t "$ROOT_FSTYPE" "$partRoot" "$MOUNT_ROOT"
if ! mountpoint -q "$MOUNT_ROOT"; then
    echo "错误：根分区挂载失败。"
    umount "$MOUNT_BOOT"
    exit 1
fi

# --- 停止所有 Docker 容器 ---
echo "--- 阶段 8/8: 停止所有 Docker 容器 ---"
RUNNING_CONTAINERS=$(docker ps -q)
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "停止容器: $RUNNING_CONTAINERS"
    docker stop $RUNNING_CONTAINERS
else
    echo "无运行的 Docker 容器。"
fi

# --- 复制引导分区内容 ---
echo "复制引导分区内容..."
cp -a "$BOOT_MOUNTPOINT/"* "$MOUNT_BOOT/"

# --- 更新 cmdline.txt 中的根 PARTUUID ---
NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID | cut -d= -f2)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID | cut -d= -f2)

if [ -f "$MOUNT_BOOT/cmdline.txt" ] && [ -w "$MOUNT_BOOT/cmdline.txt" ]; then
    sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/g" "$MOUNT_BOOT/cmdline.txt"
else
    echo "警告：cmdline.txt 不存在或不可写，跳过更新。"
fi

# --- 复制根文件系统内容 ---
echo "复制根文件系统内容 (这可能需要较长时间)..."
rsync -aAXv --delete \
    --exclude="/dev/*" --exclude="/proc/*" --exclude="/sys/*" --exclude="/run/*" \
    --exclude="/media/*" --exclude="/tmp/*" --exclude="/mnt/*" --exclude="/lost+found" \
    --exclude="$BACKUP_DIR/*" --exclude="$(pwd)/*" \
    / "$MOUNT_ROOT/"

# --- 创建空目录 ---
for d in dev proc sys run media mnt boot tmp; do
    mkdir -p "$MOUNT_ROOT/$d"
done
chmod a+w "$MOUNT_ROOT/tmp"

# --- 更新 fstab 中 PARTUUID ---
if [ -f "$MOUNT_ROOT/etc/fstab" ] && [ -w "$MOUNT_ROOT/etc/fstab" ]; then
    sed -i "s/$ORIG_BOOT_PARTUUID/$NEW_BOOT_PARTUUID/g" "$MOUNT_ROOT/etc/fstab"
    sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/g" "$MOUNT_ROOT/etc/fstab"
else
    echo "警告：fstab 不存在或不可写，跳过更新。"
fi

sync

# --- 卸载镜像分区 ---
umount "$MOUNT_BOOT"
umount "$MOUNT_ROOT"
rmdir "$MOUNT_BOOT" "$MOUNT_ROOT"

# --- 恢复 Docker 容器 ---
echo "恢复之前停止的 Docker 容器..."
if [ -n "$RUNNING_CONTAINERS" ]; then
    docker start $RUNNING_CONTAINERS || echo "警告：Docker 容器启动失败。"
else
    echo "无 Docker 容器需要恢复。"
fi

echo "✅ 备份完成，镜像路径：$DEST_IMG_PATH"

# 脚本结束，cleanup 自动执行
