#!/bin/bash

# ====================================================
# Raspberry Pi 系统盘完整备份脚本（支持 NVMe）
# 备份基于已用空间+20%余量估算大小
# 备份时自动停止所有 Docker 容器，备份完成后恢复
# 不排除任何目录，完整备份
# 需要 root 权限运行
# ====================================================

# --- 配置变量 ---
BACKUP_DIR="/media/8T/4Backups/Backup"  # 备份存储目录

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行脚本（sudo）。"
    exit 1
fi

# --- 安装必要软件 ---
echo "--- 阶段 1/8: 检查并安装所需软件 ---"
REQUIRED_PKGS="dosfstools parted kpartx rsync jq"
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        echo "安装软件包：$pkg ..."
        apt update && apt install -y "$pkg" || {
            echo "安装 $pkg 失败，退出。"
            exit 1
        }
    fi
done
echo "所有必需软件已安装。"

# --- 清理函数 ---
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

# --- 创建备份目录 ---
echo "--- 阶段 2/8: 准备备份目录 ---"
mkdir -p "$BACKUP_DIR" || {
    echo "错误：无法创建备份目录 $BACKUP_DIR"
    exit 1
}
echo "备份目录已确认或创建：$BACKUP_DIR"

# --- 自动检测系统盘 ---
echo "--- 阶段 3/8: 自动检测系统盘信息 ---"
ROOT_DEVICE_PARTITION=$(df -P / | tail -n 1 | awk '{print $1}')

if [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/sd[a-z]+)[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
elif [[ "$ROOT_DEVICE_PARTITION" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    SD_DEVICE="${BASH_REMATCH[1]}"
else
    echo "错误：无法识别根目录设备类型（非 mmcblk/sd/nvme），退出。"
    exit 1
fi

BOOT_PART="${SD_DEVICE}1"
ROOT_PART="${SD_DEVICE}2"

PART_INFO=$(lsblk -o NAME,FSTYPE,MOUNTPOINT,MOUNTPOINTS,PARTUUID,SIZE -J "$SD_DEVICE") || {
    echo "错误：获取设备 $SD_DEVICE 分区信息失败。"
    exit 1
}

BOOT_MOUNTPOINT=$(echo "$PART_INFO" | jq -r "
  .blockdevices[] | (.children[]? // .) |
  select(.name == \"$(basename "$BOOT_PART")\") |
  (.mountpoint // .mountpoints[0] // \"\")
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

if [ -z "$BOOT_MOUNTPOINT" ] || [ -z "$ORIG_BOOT_PARTUUID" ] || [ -z "$ORIG_ROOT_PARTUUID" ]; then
    echo "错误：无法获取关键分区信息，退出。"
    exit 1
fi

# --- 计算镜像大小（已用空间 + 20%余量） ---
ROOT_USED_KB=$(df -P "$ROOT_DEVICE_PARTITION" | tail -1 | awk '{print $3}')
BOOT_TOTAL_KB=$(df -P "$BOOT_MOUNTPOINT" | tail -1 | awk '{print $2}')
TOTAL_KB=$((ROOT_USED_KB + BOOT_TOTAL_KB))
IMAGE_SIZE_KB=$((TOTAL_KB * 120 / 100))

echo "系统盘设备: $SD_DEVICE"
echo "引导分区挂载点: $BOOT_MOUNTPOINT (PARTUUID: $ORIG_BOOT_PARTUUID)"
echo "根分区 PARTUUID: $ORIG_ROOT_PARTUUID"
echo "估算镜像大小: $IMAGE_SIZE_KB KB (~$((IMAGE_SIZE_KB / 1024)) MB)"

read -p "确认开始备份？(y/N): " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "备份已取消。"
    exit 0
fi

# --- 停止 Docker 容器 ---
echo "--- 停止运行中的 Docker 容器 ---"
RUNNING_CONTAINERS=$(docker ps -q)
if [ -n "$RUNNING_CONTAINERS" ]; then
    docker stop $RUNNING_CONTAINERS || echo "警告：停止 Docker 容器失败，请检查。"
else
    echo "无运行中的 Docker 容器。"
fi

# --- 创建镜像文件 ---
echo "--- 阶段 4/8: 创建空镜像文件 ---"
IMAGE_FILE="rpi-$(date +%Y%m%d%H%M%S).img"
DEST_IMG_PATH="$BACKUP_DIR/$IMAGE_FILE"
dd if=/dev/zero of="$DEST_IMG_PATH" bs=1K count=0 seek="$IMAGE_SIZE_KB" status=progress || {
    echo "错误：创建镜像文件失败。"
    exit 1
}

# --- 创建分区表 ---
echo "--- 阶段 5/8: 创建分区表 ---"
PARTED_INFO=$(fdisk -l "$SD_DEVICE")
BOOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $2}')
BOOT_END_SECTOR=$(echo "$PARTED_INFO" | grep "^${BOOT_PART}" | awk '{print $3}')
ROOT_START_SECTOR=$(echo "$PARTED_INFO" | grep "^${ROOT_PART}" | awk '{print $2}')
if [ -z "$BOOT_START_SECTOR" ] || [ -z "$BOOT_END_SECTOR" ] || [ -z "$ROOT_START_SECTOR" ]; then
    echo "错误：解析分区起始/结束扇区失败。"
    exit 1
fi

parted "$DEST_IMG_PATH" --script mklabel msdos
parted "$DEST_IMG_PATH" --script mkpart primary fat32 "${BOOT_START_SECTOR}s" "${BOOT_END_SECTOR}s"
parted "$DEST_IMG_PATH" --script mkpart primary ext4 "${ROOT_START_SECTOR}s" 100%

# --- 挂载并格式化镜像 ---
echo "--- 阶段 6/8: 挂载并格式化镜像分区 ---"
loopdevice=$(losetup -f --show "$DEST_IMG_PATH") || {
    echo "错误：设置循环设备失败。"
    exit 1
}
kpartx -va "$loopdevice" || {
    echo "错误：映射循环设备分区失败。"
    exit 1
}
sleep 2
device_mapper=$(basename "$loopdevice")
partBoot="/dev/mapper/${device_mapper}p1"
partRoot="/dev/mapper/${device_mapper}p2"
if [ ! -b "$partBoot" ] || [ ! -b "$partRoot" ]; then
    echo "错误：映射的分区设备不存在。"
    exit 1
fi

mkfs.vfat -F32 -n boot "$partBoot" || {
    echo "错误：格式化引导分区失败。"
    exit 1
}
mkfs.ext4 -F "$partRoot" || {
    echo "错误：格式化根分区失败。"
    exit 1
}
e2label "$partRoot" rootfs

# --- 复制数据 ---
echo "--- 阶段 7/8: 复制数据 ---"
mkdir -p /mnt/boot_temp /mnt/root_temp
mount -t "$BOOT_FSTYPE" "$partBoot" /mnt/boot_temp || { echo "挂载引导分区失败"; exit 1; }
mount -t "$ROOT_FSTYPE" "$partRoot" /mnt/root_temp || { echo "挂载根分区失败"; exit 1; }

echo "复制引导分区内容..."
cp -rfp "${BOOT_MOUNTPOINT}"/* /mnt/boot_temp/ || { echo "复制引导分区失败"; exit 1; }

NEW_BOOT_PARTUUID=$(blkid -o export "$partBoot" | grep PARTUUID | cut -d= -f2)
NEW_ROOT_PARTUUID=$(blkid -o export "$partRoot" | grep PARTUUID | cut -d= -f2)

if [ -f /mnt/boot_temp/cmdline.txt ]; then
    sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/g" /mnt/boot_temp/cmdline.txt
fi

echo "复制根文件系统内容，可能耗时较长，请耐心等待..."
rsync -aAXv /* /mnt/root_temp \
    --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* \
    --exclude=/tmp/* --exclude=/media/* --exclude=/mnt/* \
    --exclude="${BACKUP_DIR}/*" --exclude="$(pwd)/*" --exclude=/boot/*

# 创建必要空目录
for d in dev proc sys run media mnt boot tmp; do
    mkdir -p /mnt/root_temp/$d
done
chmod a+w /mnt/root_temp/tmp

# 更新 fstab 中 PARTUUID
if [ -f /mnt/root_temp/etc/fstab ]; then
    sed -i "s/$ORIG_BOOT_PARTUUID/$NEW_BOOT_PARTUUID/g" /mnt/root_temp/etc/fstab
    sed -i "s/$ORIG_ROOT_PARTUUID/$NEW_ROOT_PARTUUID/g" /mnt/root_temp/etc/fstab
fi

sync
umount /mnt/boot_temp
umount /mnt/root_temp
rmdir /mnt/boot_temp /mnt/root_temp

# --- 恢复 Docker 容器 ---
echo "--- 阶段 8/8: 恢复 Docker 容器 ---"
if [ -n "$RUNNING_CONTAINERS" ]; then
    docker start $RUNNING_CONTAINERS || echo "警告：Docker 容器启动失败。"
else
    echo "无 Docker 容器需要恢复。"
fi

echo "✅ 备份完成，镜像路径：$DEST_IMG_PATH"
