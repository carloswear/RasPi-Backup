# RasPi-Backup
Tested on my Pi 4B/5 64bit bookworm

-----

# 树莓派系统备份脚本 (Raspberry Pi System Backup Script)

这是一个用于创建树莓派或其他基于Debian系统的可启动镜像备份的Shell脚本。它能够自动检测系统盘，处理分区，并将您的操作系统完整地备份到一个可用于烧录的`.img`文件。脚本还包含一个可选功能，可以在备份前停止并备份后恢复Docker容器。

This is a Shell script designed to create bootable image backups of your Raspberry Pi or other Debian-based systems. It automatically detects the system disk, handles partitions, and backs up your entire operating system into a ready-to-flash `.img` file. The script also includes an optional feature to stop Docker containers before backup and restart them afterward.

## 功能 (Features)

  * **自动化 (Automation)**: 自动检测系统启动盘（`/dev/sda` 或 `/dev/mmcblk0` 等）。
  * **依赖安装 (Dependency Installation)**: 自动检查并安装所需的软件包 (`dosfstools`, `parted`, `kpartx`, `rsync`, `jq`)。
  * **Docker 容器管理 (Docker Container Management)**: **可选**在备份前停止所有运行中的 Docker 容器，并在备份完成后自动恢复，确保数据一致性。
  * **镜像大小选择 (Image Size Selection)**:
      * **精准备份 (Precise Backup)**: 仅备份已使用的空间加上少量余量，生成更小的镜像文件。
      * **完整镜像 (Full Image)**: 备份整个磁盘空间，与原始磁盘大小一致。
  * **分区表和文件系统处理 (Partition Table and Filesystem Handling)**: 在新镜像中创建与原系统一致的分区表，并格式化分区。
  * **数据同步 (Data Synchronization)**: 使用 `rsync` 高效复制数据，并排除不必要的文件（如 `/dev`, `/proc`, `/sys`, `/tmp`, `swapfile`）。
  * **PARTUUID 更新 (PARTUUID Update)**: 自动更新 `cmdline.txt` 和 `fstab` 中的 PARTUUID，确保新镜像的可启动性。
  * **清理机制 (Cleanup Mechanism)**: 脚本在退出时（无论成功或失败）都会自动清理临时挂载点和循环设备。

## 使用方法 (Usage)

1.  **保存脚本 (Save the Script)**:
    将上述脚本内容保存到一个文件，例如 `backup.sh`。

    Save the script content above to a file, for example, `backup.sh`.

2.  **添加执行权限 (Add Execute Permissions)**:

    ```bash
    chmod +x backup.sh
    ```

3.  **运行脚本 (Run the Script)**:
    **重要提示**: 脚本需要 `root` 权限才能运行。

    **Important**: The script requires `root` privileges to run.

    ```bash
    sudo ./backup.sh
    ```

4.  **按提示操作 (Follow the Prompts)**:

      * 脚本会提示您是否安装缺失的依赖。
      * 如果检测到 Docker 容器，会询问是否停止它们。
      * 在创建镜像前，会要求您确认即将执行的操作和估算的镜像大小。
      * 选择备份模式（精简或完整）。

## 脚本配置 (Script Configuration)

您可以修改脚本开头的配置变量：

You can modify the configuration variables at the beginning of the script:

  * `BACKUP_DIR`: 备份镜像文件的保存目录。默认是 `/media/8T/4Backups/Backup`。请确保此目录存在并有足够的空间。
    (The directory where backup image files will be saved. Default is `/media/8T/4Backups/Backup`. Please ensure this directory exists and has sufficient space.)

  * `IMAGE_LABEL_BOOT`: 新镜像中引导分区的卷标。默认为 `boot`。
    (The label for the boot partition in the new image. Default is `boot`.)

  * `IMAGE_LABEL_ROOT`: 新镜像中根分区的卷标。默认为 `rootfs`。
    (The label for the root partition in the new image. Default is `rootfs`.)

## 注意事项与故障排除 (Notes and Troubleshooting)

  * **权限 (Permissions)**: 始终使用 `sudo` 运行脚本。
    (Always run the script with `sudo`.)
  * **磁盘空间 (Disk Space)**: 确保 `BACKUP_DIR` 有足够的空间来存储生成的镜像文件。
    (Ensure `BACKUP_DIR` has enough space to store the generated image file.)
  * **Docker 容器 (Docker Containers)**: 如果您不希望脚本自动停止和恢复 Docker 容器，可以注释掉脚本中相关的 Docker 部分。
    (If you don't want the script to automatically stop and restart Docker containers, you can comment out the relevant Docker sections in the script.)
  * **镜像写入 (Flashing the Image)**: 创建的 `.img` 文件可以使用 Raspberry Pi Imager、balenaEtcher 等工具写入到新的 SD 卡或 USB 启动盘。
    (The created `.img` file can be written to a new SD card or USB boot drive using tools like Raspberry Pi Imager, balenaEtcher, etc.)
  * **PARTUUID 错误 (PARTUUID Errors)**: 如果在新镜像启动时遇到 PARTUUID 错误，请检查 `cmdline.txt` 和 `fstab` 文件中的 PARTUUID 是否正确更新。脚本已包含自动更新逻辑，但在特殊情况下可能需要手动核对。
    (If you encounter PARTUUID errors when booting the new image, please check if the PARTUUIDs in `cmdline.txt` and `fstab` files are correctly updated. The script includes automatic update logic, but manual verification might be needed in special cases.)
  * **`jq` 解析问题 (jq Parsing Issues)**: 如果脚本在“阶段 3”中报告获取分区信息失败，这通常是 `jq` 解析 `lsblk` JSON 输出的问题。尽管脚本已包含健壮的 `jq` 表达式，但不同系统版本或 `lsblk` / `jq` 版本之间的细微差异可能导致此问题。
      * **调试方法 (Debugging Method)**:
        在脚本中找到“阶段 3”部分，取消注释或添加 `echo "DEBUG: ..."` 行来打印 `lsblk` 的原始 JSON 输出以及 `jq` 提取的变量值。将这些调试输出提供给专业人士可以帮助诊断。
        (If the script fails to retrieve partition information in "Phase 3", this is usually a `jq` parsing issue with the `lsblk` JSON output. Although the script contains robust `jq` expressions, subtle differences between system versions or `lsblk`/`jq` versions might cause this.
        **Debugging Method**:
        Locate the "Phase 3" section in the script and uncomment or add `echo "DEBUG: ..."` lines to print the raw `lsblk` JSON output and the variable values extracted by `jq`. Providing these debug outputs to a professional can help diagnose the issue.)
