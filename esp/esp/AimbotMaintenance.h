#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Aimbot is disabled in this build. Kept as a function so call sites can
/// document the reason instead of hardcoding NO everywhere.
BOOL AimbotMaintenanceActive(void);

/// Presents the "Aimbot đang được bảo trì." notice on the main thread.
/// Safe to call from any thread; debounced so a burst of setter calls cannot
/// stack alerts.
void AimbotShowMaintenanceAlert(void);

#ifdef __cplusplus
}
#endif
