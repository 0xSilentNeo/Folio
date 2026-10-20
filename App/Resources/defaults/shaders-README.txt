mpv shaders
===========

Put GLSL user shaders (*.glsl, *.hook) here, then turn them on in
GlassPlayer → Settings → Shaders, or from the player's Shaders menu.
Active shaders are applied in the order you enable them.

Limits on iOS
- Rendering uses OpenGL ES 3.0: shaders that use compute (//!COMPUTE)
  will fail to load. Anime4K, FSRCNNX, KrigBilateral, SSimSuperRes and
  adaptive-sharpen are fragment shaders and work.
- Heavy shaders cost battery and can drop frames on 4K content.
- Shaders are skipped while Picture in Picture is active.
