
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSString *ESPPrefsPath(void);

void ESPPrefsSetBool(NSString *key, BOOL value);
void ESPPrefsSetFloat(NSString *key, float value);
// Memory-only write (no disk schedule). Use while dragging UI; call ESPPrefsSync() on touch end.
void ESPPrefsSetFloatLive(NSString *key, float value);
void ESPPrefsSetBoolLive(NSString *key, BOOL value);
void ESPPrefsSync(void);

// Re-reads the prefs file if another process has written it, then nothing.
// Call it from the place that already re-reads settings on a slow tick.
//
// This exists because the cache is per process and filled once. The UI process
// writes; the process that runs the engine reads. Without a reload the reader
// keeps whatever it saw on its first read, so a setting changed in the app
// looks like it did nothing for as long as the process lives.
void ESPPrefsReloadIfChanged(void);

BOOL ESPPrefsBool(NSString *key, BOOL defaultValue);
float ESPPrefsFloat(NSString *key, float defaultValue);

id AppSettingsObjectForKey(NSString *key);
void AppSettingsSetObject(NSString *key, id value);
void AppSettingsRemoveKeys(NSArray<NSString *> *keys);

#ifdef __cplusplus
}
#endif
