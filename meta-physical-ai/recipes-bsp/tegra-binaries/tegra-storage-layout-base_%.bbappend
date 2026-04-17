PHYSICAL_AI_PARTITION_FILE := "${THISDIR}/files/flash_l4t_t234_nvme_physical_ai_rootfs_ab.xml"
do_install[file-checksums] += "${PHYSICAL_AI_PARTITION_FILE}:True"

# Use the repo-local NVMe partition template for the Orin Nano devkit NVMe
# target so the generated tegraflash bundle matches the intended 1 TB A/B layout.
PARTITION_FILE_EXTERNAL:jetson-orin-nano-devkit-nvme = "${PHYSICAL_AI_PARTITION_FILE}"
