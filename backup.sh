#!/bin/bash

# === 配置变量 Configuration ===
BACKUP_DIR="/media/8T/4Backups/Backup"  # 镜像备份目录

# === 权限检查 Root check ===
if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本必须以 root 权限运行。请使用 sudo 执行。"
    exit 1
fi

# === 安装所需软件 Install required packages ===
echo "--- 阶段 1/8: 检查并安装所需软件 ---"
REQUIRED_PKGS="dosfstools parted kpartx rsync jq docker.io"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "安装 $pkg..."
        apt update && apt install -y "$pkg" || {
            echo "安装 $pkg 失败，退出。"
            exit 1
        }
    fi
done
echo "所有软件已就绪。"

# === 定义清理函数 Cleanup function ===
cleanup() {
    echo "--- 执行清理操作 ---"
    umount /mnt/boot_temp &>/dev/null && rmdir /mnt/boot_temp &>/dev/null
    umount /mnt/root_temp &>/dev/null && rmdir /mnt/root_temp &>/dev/null
    if [ -n "$loopdevice" ] && losetup "$loopdevice" &>/dev/null; then
        kpartx -d "$loopdevice" &>/dev/null
        losetup -d "$loopdevice" &>/dev/null
        echo "已卸载循环设备 $loopdevice。"
    fi
}
trap cleanup EXIT

# === 创建备份目录 ===
echo "--- 阶段 2/8: 准备备份目录 ---"
mkdir -p "$BACKUP_DIR" || {
    echo "无法创建目录 $BACKUP_DIR"
    exit 1
}
echo "备份目录就绪：$BACKUP_DIR"

# === 获取系统盘信息 Detect system disk ===
echo "--- 阶段 3/8: 自动检测系统盘信息 ---"
ROOT_DEVICE_PARTITION=$(df -P / | tail -n 1 | awk '{print $1}')
if [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
else
    echo "无法识别系统盘设备。退出。"
    exit 1
fi

BOOT_PART="${SD_DEVICE}1"
ROOT_PART="${SD_DEVICE}2"

# === 获取分区信息 Extract info from lsblk ===
echo "--- 解析系统分区结构 ---"
PART_INFO=$(lsblk -o NAME,FSTYPE,MOUNTPOINT,MOUNTPOINTS,PARTUUID,SIZE -J "$SD_DEVICE") || {
    echo "获取分区信息失败。"
    exit 1
}

BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$BOOT_PART")\") |
  (.mountpoint // .mountpoints[0] // \"\")
")
ORIG_BOOT_PARTUUID=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$BOOT_PART")\") |
  (.partuuid // \"\")
")
ORIG_ROOT_PARTUUID=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$ROOT_PART")\") |
  (.partuuid // \"\")
")
BOOT_FSTYPE=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$BOOT_PART")\") |
  (.fstype // \"\")
")
ROOT_FSTYPE=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$ROOT_PART")\") |
  (.fstype // \"\")
")

if [ -z "$BOOT_MOUNTPOINT" ] || [ -z "$ORIG_BOOT_PARTUUID" ] || [ -z "$ORIG_ROOT_PARTUUID" ]; then
    echo "错误：无法解析关键分区信息。退出。"
    exit 1
fi

# === 计算镜像大小（基于实际使用量+5%余量）===
echo "--- 估算镜像大小（基于已用空间+5%余量） ---"
ROOT_USED_KB=$(df -P "$ROOT_DEVICE_PARTITION" | tail -1 | awk '{print $3}')
BOOT_TOTAL_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -1 | awk '{print $2}')
TOTAL_KB=$((ROOT_USED_KB + BOOT_TOTAL_KB))
IMAGE_SIZE_KB=$((TOTAL_KB * 105 / 100))

echo "根分区已用: $ROOT_USED_KB KB"
echo "引导分区总大小: $BOOT_TOTAL_KB KB"
echo "镜像文件大小估算: $IMAGE_SIZE_KB KB (~$((IMAGE_SIZE_KB / 1024)) MB)"

# === 用户确认 Confirmation ===
read -p "是否继续创建系统备份？(y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "已取消。"; exit 0; }

# === 停止所有运行中的 Docker 容器 ===
echo "--- 停止正在运行的 Docker 容器 ---"
RUNNING_CONTAINERS=$(docker ps -q)
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "检测到运行中的容器，准备停止..."
    docker stop $RUNNING_CONTAINERS
    if [ $? -ne 0 ]; then
        echo "警告：停止部分容器失败，请手动检查。"
    fi
else
    echo "无运行中的 Docker 容器。"
fi

# === 创建镜像文件 ===
echo "--- 阶段 4/8: 创建镜像文件 ---"
IMAGE_NAME="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="$BACKUP_DIR/$IMAGE_NAME"
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress || {
    echo "镜像创建失败。"
    exit 1
}

# === 创建分区表 Partition image ===
echo "--- 阶段 5/8: 写入分区表 ---"
PARTED_INFO=$(fdisk -l "$SD_DEVICE")
BOOT_START=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $2}')s
BOOT_END=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $3}')s
ROOT_START=$(echo "$PARTED_INFO" | grep "^${ROOT_PART}" | awk '{print $2}')s

parted "$DEST_IMG_PATH" --script -- mklabel msdos
parted "$DEST_IMG_PATH" --script -- mkpart primary fat32 "$BOOT_START" "$BOOT_END"
parted "$DEST_IMG_PATH" --script -- mkpart primary ext4 "$ROOT_START" 100%

# === 挂载并格式化镜像 Format partitions ===
echo "--- 阶段 6/8: 格式化分区 ---"
loopdevice=$(losetup -f --show "$DEST_IMG_PATH") || exit 1
kpartx -va "$loopdevice" || exit 1
sleep 2
device_mapper=$(basename "$loopdevice")
partBoot="/dev/mapper/${device_mapper}p1"
partRoot="/dev/mapper/${device_mapper}p2"
mkfs.vfat -F 32 -n boot "$partBoot"
mkfs.ext4 -F "$partRoot" && e2label "$partRoot" "rootfs"

# === 数据复制 Copy data ===
echo "--- 阶段 7/8: 拷贝系统数据 ---"
mkdir -p /mnt/boot_temp /mnt/root_temp
mount -t "$BOOT_FSTYPE" "$partBoot" /mnt/boot_temp
mount -t "$ROOT_FSTYPE" "$partRoot" /mnt/root_temp

echo "复制引导分区..."
cp -rfp "${BOOT_MOUNTPOINT}"/* /mnt/boot_temp/

NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID | cut -d= -f2)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID | cut -d= -f2)
[ -f /mnt/boot_temp/cmdline.txt ] && sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/" /mnt/boot_temp/cmdline.txt

echo "复制根文件系统..."
rsync -aAXv /* /mnt/root_temp \
    --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* \
    --exclude=/tmp/* --exclude=/media/* --exclude=/mnt/* \
    --exclude="${BACKUP_DIR}/*" --exclude="$(pwd)/*" --exclude=/boot/*

for dir in dev proc sys run tmp mnt media boot; do
    mkdir -p "/mnt/root_temp/$dir"
done
chmod 1777 /mnt/root_temp/tmp

[ -f /mnt/root_temp/etc/fstab ] && {
    sed -i "s/$ORIG_BOOT_PARTUUID/$NEW_BOOT_PARTUUID/" /mnt/root_temp/etc/fstab
    sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/" /mnt/root_temp/etc/fstab
}

# === 卸载 ===
echo "--- 阶段 8/8: 清理与完成 ---"
sync
umount /mnt/boot_temp /mnt/root_temp
rmdir /mnt/boot_temp /mnt/root_temp

# === 恢复之前停止的 Docker 容器 ===
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "--- 恢复之前停止的 Docker 容器 ---"
    docker start $RUNNING_CONTAINERS
    if [ $? -ne 0 ]; then
        echo "警告：启动部分容器失败，请手动检查。"
    else
        echo "Docker 容器已恢复运行。"
    fi
fi

echo "✅ 备份完成！镜像路径：$DEST_IMG_PATH"
