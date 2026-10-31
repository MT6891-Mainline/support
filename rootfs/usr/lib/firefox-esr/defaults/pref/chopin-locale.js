// chopin: force the Firefox UI to Simplified Chinese.
//
// Requires the language pack (apt install firefox-esr-l10n-zh-cn); the pack is
// only used when Firefox is told to use it, so make the choice explicit instead
// of relying on whatever locale the session happened to have on first launch.
pref("intl.locale.requested", "zh-CN");
