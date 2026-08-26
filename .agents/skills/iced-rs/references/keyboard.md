# Keyboard

> `iced::keyboard` · iced 0.14.0

Keyboard input: `Event` (key press/release/modifiers changed), `Key` (named or character), `Modifiers` (bit flags), and `keyboard::listen()` subscription. Events arrive via `Widget::update` or global subscriptions.

## API

### `keyboard::Event` enum

```rust
pub enum Event {
    KeyPressed {
        key:          Key,
        modified_key: Key,
        physical_key: Physical,
        location:     Location,
        modifiers:    Modifiers,
        text:         Option<SmolStr>,
        repeat:       bool,
    },
    KeyReleased {
        key:          Key,
        modified_key: Key,
        physical_key: Physical,
        location:     Location,
        modifiers:    Modifiers,
    },
    ModifiersChanged(Modifiers),
}
```

Use `key` for combinations (Ctrl+C), `modified_key` for single-key bindings, `physical_key` for layout-independent bindings (WASD).

### `keyboard::Key` enum

```rust
pub enum Key<C = SmolStr> {
    Named(Named),
    Character(C),
    Unidentified,
}

impl Key {
    pub fn as_ref(&self) -> Key<&str>;
    pub fn to_latin(&self, physical_key: Physical) -> Option<char>;
}
```

### `keyboard::key::Named` enum (full variants)

```rust
pub enum Named {
    // === Modifier keys ===
    Alt, AltGraph, CapsLock, Control, Fn, FnLock, NumLock, ScrollLock,
    Shift, Symbol, SymbolLock, Meta, Hyper, Super,

    // === Whitespace / editing ===
    Enter, Tab, Space,

    // === Editing keys ===
    Backspace, Clear, Delete, Insert,
    Copy, Cut, Paste, Redo, Undo,
    EraseEof, ExSel, CrSel,

    // === Navigation ===
    ArrowDown, ArrowLeft, ArrowRight, ArrowUp,
    End, Home, PageDown, PageUp,

    // === UI / control keys ===
    Accept, Again, Attn, Cancel, ContextMenu, Escape, Execute,
    Find, Help, Pause, Play, Props, Select,
    ZoomIn, ZoomOut,

    // === Function keys (F1-F35) ===
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24, F25,
    F26, F27, F28, F29, F30, F31, F32, F33, F34, F35,

    // === Media keys ===
    AudioBalanceLeft, AudioBalanceRight,
    AudioBassBoostDown, AudioBassBoostToggle, AudioBassBoostUp,
    AudioFaderFront, AudioFaderRear,
    AudioSurroundModeNext, AudioTrebleDown, AudioTrebleUp,
    AudioVolumeDown, AudioVolumeUp, AudioVolumeMute,
    MicrophoneToggle, MicrophoneVolumeDown, MicrophoneVolumeMute,
    MicrophoneVolumeUp,

    // === Media control ===
    MediaFastForward, MediaPause, MediaPlay, MediaPlayPause,
    MediaRecord, MediaRewind, MediaStop, MediaTrackNext,
    MediaTrackPrevious,

    // === Speech ===
    SpeechCorrectionList, SpeechInputToggle,

    // === Application launch keys ===
    LaunchApplication1, LaunchApplication2,
    LaunchCalendar, LaunchContacts, LaunchMail,
    LaunchMediaPlayer, LaunchMusicPlayer,
    LaunchPhone, LaunchScreenSaver, LaunchSpreadsheet,
    LaunchWebBrowser, LaunchWebCam, LaunchWordProcessor,

    // === Browser keys ===
    BrowserBack, BrowserFavorites, BrowserForward,
    BrowserHome, BrowserRefresh, BrowserSearch, BrowserStop,

    // === Numeric keypad ===
    // (numeric keypad keys map to Character, not Named)

    // === TV / device keys ===
    AVRInput, AVRPower, ChannelDown, ChannelUp, ColorF0Red,
    ColorF1Green, ColorF2Yellow, ColorF3Blue, DVR, Guide,
    Info, InstantReplay, Link, ListProgram, LiveContent,
    Lock, NextFavoriteChannel, OnDemand, PinPDown, PinPMove,
    PinPToggle, PinPUp, PlaySpeedDown, PlaySpeedReset,
    PlaySpeedUp, RandomToggle, RcLowBattery, RecordSpeedNext,
    RfBypass, ScanChannelsToggle, ScreenModeNext,
    Settings, SplitScreenToggle, STBInput, STBPower,
    Subtitle, Teletext, TV, TV3DMode, TVAntennaCable,
    TVAudioDescription, TVAudioDescriptionMixDown,
    TVAudioDescriptionMixUp, TVContentsMenu, TVDataService,
    TVInput, TVInputComponent1, TVInputComponent2,
    TVInputComposite1, TVInputComposite2, TVInputHDMI1,
    TVInputHDMI2, TVInputHDMI3, TVInputHDMI4, TVInputVGA1,
    TVMediaContext, TVNetwork, TVNumberEntry, TVPower,
    TVRadioService, TVSatellite, TVSatelliteBS, TVSatelliteCS,
    TVSatelliteToggle, TVTerrestrialAnalog, TVTerrestrialDigital,
    TVTimer, VideoModeNext,

    // === IME / composition ===
    AllCandidates, Alphanumeric, CodeInput, Compose, Convert,
    FinalMode, GroupFirst, GroupLast, GroupNext, GroupPrevious,
    ModeChange, NextCandidate, NonConvert, PreviousCandidate,
    Process, SingleCandidate,
    HangulMode, HanjaMode, JunjaMode,
    Eisu, Hankaku, Hiragana, HiraganaKatakana, KanaMode,
    KanjiMode, Katakana, Romaji, Zenkaku, ZenkakuHankaku,

    // === Document keys ===
    Close, MailForward, MailReply, MailSend, New, Open, Print,
    Save, SpellCheck,

    // === Special ===
    Key11, Key12,  // non-standard key positions
    Unidentified,
    Soft1, Soft2, Soft3, Soft4,
    GoBack, GoHome,
    AppSwitch, Call, Camera, CameraFocus, EndCall,
    MannerMode, VoiceDial, NavigateIn, NavigateNext,
    NavigateOut, NavigatePrevious,
    Standby, WakeUp,
    Abort, Resume, Suspend, Power, PowerOff, Hibernate,
    BrightnessDown, BrightnessUp,
    DisplayToggleIntExt, KeyboardLayoutSelect,
    LaunchAssistant, Symbol, PrintScreen,
}
```

### `keyboard::Modifiers` struct

Bit-flag struct:

```rust
impl Modifiers {
    pub const SHIFT:   Modifiers;
    pub const CTRL:    Modifiers;
    pub const ALT:     Modifiers;
    pub const LOGO:    Modifiers;   // Windows/Command/Super
    pub const COMMAND: Modifiers;   // platform primary: LOGO on macOS, CTRL elsewhere

    pub fn empty() -> Modifiers;
    pub fn all() -> Modifiers;
    pub fn bits() -> u32;

    pub fn contains(other: Modifiers) -> bool;
    pub fn insert(&mut self, other: Modifiers);
    pub fn remove(&mut self, other: Modifiers);
    pub fn toggle(&mut self, other: Modifiers);

    pub fn shift() -> bool;
    pub fn control() -> bool;
    pub fn alt() -> bool;
    pub fn logo() -> bool;
}
```

- **`SHIFT` / `CTRL` / `ALT` / `LOGO`** — The four primary modifier bits.
- **`COMMAND`** — Platform-aware alias: `LOGO` on macOS, `CTRL` elsewhere.
  Use this when you want "Ctrl+C on Linux/Windows, Cmd+C on macOS".
- **`contains(other)`** — Returns true if all bits in `other` are set.
- **`shift()` / `control()` / `alt()` / `logo()`** — Convenience accessors.

### Helper subscriptions

```rust
pub fn iced::keyboard::listen() -> Subscription<Event>;
```

Returns a `Subscription<keyboard::Event>` that yields every keyboard event
the runtime receives. For finer control (filtering, mapping), use
`iced::event::listen_with`.

## Patterns

### Listen globally

```rust
use iced::keyboard;

fn subscription(_: &State) -> Subscription<Message> {
    keyboard::listen().map(Message::KeyboardEvent)
}
```

### Ctrl/Cmd+S as a shortcut using `COMMAND`

```rust
use iced::keyboard::{self, Key, Modifiers};

if let Event::Keyboard(keyboard::Event::KeyPressed {
    key: Key::Character(c),
    modifiers,
    ..
}) = event {
    if c.as_str() == "s" && modifiers.contains(Modifiers::COMMAND) {
        shell.publish(Message::Save);
        shell.capture_event();
    }
}
```

### Layout-independent WASD

```rust
use iced::keyboard::{self, key::Physical};

if let Event::Keyboard(keyboard::Event::KeyPressed { physical_key, .. }) = event {
    match physical_key {
        Physical::Code(Code::KeyW) => { /* forward */ }
        Physical::Code(Code::KeyA) => { /* strafe left */ }
        Physical::Code(Code::KeyS) => { /* backward */ }
        Physical::Code(Code::KeyD) => { /* strafe right */ }
        _ => {}
    }
}
```

### Map Cyrillic to Latin via `to_latin`

```rust
use iced_core::keyboard::key::{Key, Named, Physical, Code};

assert_eq!(
    Key::Character("с".into()).to_latin(Physical::Code(Code::KeyC)),
    Some('c'),
);
```

## Gotchas

- **`key` vs `modified_key` vs `physical_key`** is the most common
  confusion. The docs give a clear rule: use `key` for combinations,
  `modified_key` for single-key bindings, `physical_key` for layout-
  independent bindings.
- `Modifiers::COMMAND` is the portable way to express "the primary
  modifier for keyboard shortcuts". Don't hard-code `CTRL` or you'll
  alienate macOS users.
- `text` is `Option<SmolStr>` because dead keys and composing characters
  may emit a press without producing text (the composition happens on the
  following key).
- `repeat` can fire many times for a held key — debounce in application
  state if your action should only happen once.
- `Key::Character(SmolStr)` may be a multi-character grapheme cluster
  (e.g. surrogate pair or ligature). Don't assume one key press = one
  char.
- `Key::Unidentified` is fairly rare but do handle it — otherwise
  exotic keys will be silently dropped.
- No "just the pressed character" helper -- pattern-match on `Key::Character` explicitly.

## See also

- `mouse.md`
- `events.md`
- `subscription.md`
