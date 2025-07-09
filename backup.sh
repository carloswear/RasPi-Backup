#!/bin/bash

# =============== 脚本配置 ================
BACKUP_DIR="/media/8T/4Backups/Backup"  # 镜像保存目录
IMAGE_LABEL_BOOT="boot"
IMAGE_LABEL_ROOT="rootfs"
DOCKER_WAS_STOPPED=0

# =============== 权限检查 ================
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请以 root 用户执行本脚本（sudo）"
    exit 1
fi

# =============== 安装依赖 ================
echo "📦 阶段 1/8: 检查依赖..."
REQUIRED_PKGS="dosfstools parted kpartx rsync jq"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "安装 $pkg..."
        apt update && apt install -y "$pkg" || { echo "❌ 安装失败：$pkg"; exit 1; }
    fi
done

# =============== 停止 Docker 容器（可选） ================
if command -v docker &>/dev/null; then
    RUNNING_CONTAINERS=$(docker ps -q)
    if [ -n "$RUNNING_CONTAINERS" ]; then
        echo "🛑 检测到正在运行的 Docker 容器："
        docker ps
        read -p "是否在备份前停止所有容器？[y/N] " stop_docker
        if [[ "$stop_docker" =~ ^[yY]$ ]]; then
            docker stop $RUNNING_CONTAINERS
            echo "✅ Docker 容器已停止。"
            DOCKER_WAS_STOPPED=1
        fi
    fi
fi

# =============== 清理函数 ================
cleanup() {
    echo "🧹 执行清理操作..."
    umount /mnt/boot_temp &>/dev/null && rmdir /mnt/boot_temp &>/dev/null
    umount /mnt/root_temp &>/dev/null && rmdir /mnt/root_temp &>/dev/null
    if [ -n "$loopdevice" ]; then
        kpartx -d "$loopdevice" &>/dev/null
        losetup -d "$loopdevice" &>/dev/null
    fi
    if [ "$DOCKER_WAS_STOPPED" == "1" ]; then
        echo "🔁 正在恢复 Docker 容器..."
        docker start $(docker ps -a -q)
    fi
    echo "✅ 清理完成。"
}
trap cleanup EXIT

# =============== 阶段 2: 创建备份目录 ================
mkdir -p "$BACKUP_DIR" || { echo "❌ 无法创建备份目录 $BACKUP_DIR"; exit 1; }

# =============== 阶段 3: 自动检测启动盘 ================
echo "🔍 自动识别系统盘..."
ROOT_PART=$(df -P / | tail -n 1 | awk '{print $1}')
if [[ "$ROOT_PART" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_PART" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_PART" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
else
    echo "❌ 无法识别系统盘设备类型：$ROOT_PART"
    exit 1
fi

# 假设 boot 分区是 p1，root 是 p2
BOOT_PART="${SD_DEVICE}p1"
ROOT_PART="${SD_DEVICE}p2"

# 读取分区信息（使用 lsblk JSON 输出）
PART_INFO=$(lsblk -o NAME,FSTYPE,MOUNTPOINT,PARTUUID,SIZE -J "$SD_DEVICE")
BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r '
    .blockdevices[] | (.children[]? // .) |
    select(.name == "'$(basename "$BOOT_PART")'") | .mountpoint // ""')
ORIG_BOOT_PARTUUID=$(echo "$PART_INFO" | jq -r '
    .blockdevices[] | (.children[]? // .) |
    select(.name == "'$(basename "$BOOT_PART")'") | .partuuid // ""')
ORIG_ROOT_PARTUUID=$(echo "$PART_INFO" | jq -r '
    .blockdevices[] | (.children[]? // .) |
    select(.name == "'$(basename "$ROOT_PART")'") | .partuuid // ""')
BOOT_FSTYPE=$(echo "$PART_INFO" | jq -r '
    .blockdevices[] | (.children[]? // .) |
    select(.name == "'$(basename "$BOOT_PART")'") | .fstype // ""')
ROOT_FSTYPE=$(echo "$PART_INFO" | jq -r '
    .blockdevices[] | (.children[]? // .) |
    select(.name == "'$(basename "$ROOT_PART")'") | .fstype // ""')

[ -z "$BOOT_MOUNTPOINT" ] && echo "❌ 找不到 boot 挂载点" && exit 1

# =============== 镜像大小估算选项 ================
echo
echo "请选择镜像大小模式："
echo "1) 精准备份（按实际使用 + 20% 余量）✅ 推荐"
echo "2) 完整镜像（整盘大小）"
read -p "输入选项 [1/2]（默认1）: " img_mode
img_mode=${img_mode:-1}

if [ "$img_mode" == "2" ]; then
    SD_CARD_TOTAL_BYTES=$(blockdev --getsize64 "$SD_DEVICE")
    IMAGE_SIZE_KB=$(((SD_CARD_TOTAL_BYTES + 100*1024*1024) / 1024))  # +100MB
else
    ROOT_USED_KB=$(df -P / | tail -n 1 | awk '{print $3}')
    BOOT_TOTAL_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -n 1 | awk '{print $2}')
    IMAGE_SIZE_KB=$(((ROOT_USED_KB + BOOT_TOTAL_KB) * 12 / 10))
fi

echo "🧮 镜像预计大小：$((IMAGE_SIZE_KB / 1024)) MB"

# =============== 用户确认 ================
read -p "是否继续创建镜像？(y/N): " confirm
[[ ! "$confirm" =~ ^[yY]$ ]] && echo "已取消。" && exit 0

# =============== 阶段 4: 创建镜像文件 ================
IMAGE_FILE_NAME="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="${BACKUP_DIR}/${IMAGE_FILE_NAME}"
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress || {
    echo "❌ 创建镜像文件失败"; exit 1;
}

# =============== 阶段 5: 写入分区表 ================
FDISK_INFO=$(fdisk -l "$SD_DEVICE")
BOOT_START=$(echo "$FDISK_INFO" | grep "^$BOOT_PART" | awk '{print $2}')
BOOT_END=$(echo "$FDISK_INFO" | grep "^$BOOT_PART" | awk '{print $3}')
ROOT_START=$(echo "$FDISK_INFO" | grep "^$ROOT_PART" | awk '{print $2}')
[ -z "$BOOT_START" ] && echo "❌ 无法获取分区扇区信息" && exit 1

parted "$DEST_IMG_PATH" --script -- mklabel msdos
parted "$DEST_IMG_PATH" --script -- mkpart primary fat32 "${BOOT_START}s" "${BOOT_END}s"
parted "$DEST_IMG_PATH" --script -- mkpart primary ext4 "${ROOT_START}s" "100%"

# =============== 阶段 6: 映射分区并格式化 ================
loopdevice=$(losetup -f --show "$DEST_IMG_PATH")
kpartx -va "$loopdevice"
sleep 2
mapper=$(basename "$loopdevice")
partBoot="/dev/mapper/${mapper}p1"
partRoot="/dev/mapper/${mapper}p2"

mkfs.vfat -F 32 -n "$IMAGE_LABEL_BOOT" "$partBoot"
mkfs.ext4 -F "$partRoot" && e2label "$partRoot" "$IMAGE_LABEL_ROOT"

# =============== 阶段 7: 数据复制 ================
mkdir -p /mnt/boot_temp /mnt/root_temp
mount "$partBoot" /mnt/boot_temp
cp -rfp "$BOOT_MOUNTPOINT"/* /mnt/boot_temp/

NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID | cut -d= -f2)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID | cut -d= -f2)

sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/boot_temp/cmdline.txt 2>/dev/null

umount /mnt/boot_temp && rmdir /mnt/boot_temp

mount "$partRoot" /mnt/root_temp
rsync --force -rltWDEgop --delete --stats --progress \
    --exclude "/dev/*" \
    --exclude "/proc/*" \
    --exclude "/sys/*" \
    --exclude "/run/*" \
    --exclude "/mnt/*" \
    --exclude "/media/*" \
    --exclude "/tmp/*" \
    --exclude "/lost+found" \
    --exclude "${BACKUP_DIR}/*" \
    --exclude "$(pwd)/*" \
    / /mnt/root_temp/

for d in dev proc sys run media mnt boot tmp; do
    mkdir -p "/mnt/root_temp/$d"
done
chmod a+w /mnt/root_temp/tmp

if [ -f /mnt/root_temp/etc/fstab ]; then
    sed -i "s/${ORIG_BOOT_PARTUUID}/${NEW_BOOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
    sed -i "s/${ORIG_ROOT_PARTUUID}/${NEW_ROOT_PARTUUID}/g" /mnt/root_temp/etc/fstab
fi

umount /mnt/root_temp && rmdir /mnt/root_temp

# =============== 阶段 8: 完成 ================
echo "✅ 镜像创建完成！文件路径：$DEST_IMG_PATH"
echo "可使用 Raspberry Pi Imager / balenaEtcher 写入镜像"
