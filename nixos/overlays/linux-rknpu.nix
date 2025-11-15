# Linux kernel overlay with RKNPU (Rockchip NPU) driver support
# Enables CONFIG_ROCKCHIP_RKNPU and related options for RK3588 devices
final: _prev: {
  linuxKernel = _prev.linuxKernel // {
    kernels = _prev.linuxKernel.kernels // {
      linux_6_17 = _prev.linuxKernel.kernels.linux_6_17.override {
        extraConfig = ''
          ROCKCHIP_RKNPU y
          ROCKCHIP_RKNPU_DEBUG_FS n
          ROCKCHIP_RKNPU_DRM_GEM n
        '';
      };
    };
  };
}
