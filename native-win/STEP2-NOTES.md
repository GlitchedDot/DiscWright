# DiscWright Stage 3, Step 2 — WinUI 3 face — work notes

Started from: stage3-windows-plan.md (WinUI 3 DECIDED by Lola),
the byte-proven C# core in core/ (untouched), and the Mac app
(native-pure/app/) as the behavioral reference — Step 2 here =
Mac Step 2 + 2.5 combined (look designed in from line one).

## Decisions taken while writing (details in APP-NOTES.md)

- Bindings: classic {Binding} + code-behind handlers (not
  x:Bind). Rationale: row/group buttons need store calls with
  the row's DataContext; classic binding keeps that simple and
  removes a whole class of blind-write compile errors that
  x:Bind template typing tends to produce.
- MVVM: hand-rolled INotifyPropertyChanged (ObservableBase).
  No CommunityToolkit dependency — one less NuGet restore risk;
  the surface needed is tiny (SetProperty + ObservableCollection).
- Sheen: painted as 72 interpolated wedge slices from the same
  stop tables — the technique the APPROVED Mac build shipped
  (its angularGradient API was absent on the target SDK). The
  brief asserted Win2D has CanvasConicGradientBrush; that type
  cannot be verified from this VM, and a wrong guess is a
  compile error on Lola's machine. Wedges carry zero API risk
  and are pixel-equivalent to the approved Mac rendering.
  PaintSheen() in DiscPainter.cs is the single swap point if
  the conic brush is ever confirmed.
- IMAPI2: typed interop ONLY where the vtable order is
  certain (IDiscMaster2 — 4 props; IDiscRecorder2 — first 7
  methods, of which Initialize/Acquire/Release are used).
  IDiscFormat2Data is driven through `dynamic` (IDispatch
  late binding resolves by NAME, so member order cannot bite).
  The ISO is handed over as an IStream from
  SHCreateStreamOnFileEx (shlwapi P/Invoke). No success is
  ever faked: every failure logs the HRESULT and finishes
  with success=false.
- Burn confirmation dialog needs a Window (XamlRoot), so —
  the one structural divergence from Swift — MainWindow owns
  the Burn Disc click for imported ISOs and calls into
  BurnService; the store keeps the state machine
  (ApplyBurnState mirrors the Swift closure).

## Files

app/DiscWright.csproj   WinUI 3, net8.0-windows10.0.19041.0,
                        unpackaged + self-contained, win-x64
app/App.xaml(.cs)       theme dictionaries (Light/Dark/Default)
                        + shared brushes; standard launch
app/app.manifest        unpackaged app manifest (DPI, asInvoker)
app/Models.cs           TrackItem / GroupItem (+ formatters)
app/Converters.cs       Bool <-> Visibility (normal + inverse)
app/TagReader.cs        port of TagReader.swift (pure C#)
app/Store.cs            DiscStore — DiscStore.swift minus the
                        Step 3 encode half
app/Imapi2Interop.cs    COM declarations + GUID table
app/BurnService.cs      dialog + STA burn thread + callbacks
app/DiscPainter.cs      drawDisc port for Win2D (wedges incl.)
app/MainWindow.xaml(.cs) layout, pickers, handlers, meter
build-app.cmd           dotnet check + build + copy output to
                        native-win/DiscWright/

## Verification done in this VM

- TagReader.cs + Models.cs compile-checked with the local
  .NET 8 SDK (they are UI-free) — see bottom of this file.
- All .cs files: brace/paren balance checked by script.
- All .xaml files: XML well-formedness checked by parser.
- NOT verifiable here: any WinUI/WinRT/Win2D/IMAPI surface.
  Lola's machine is the compile check (expected error loop).

## Results of in-VM checks

- Models.cs + TagReader.cs: compiled with the local .NET 8
  SDK (net8.0 library project) — 0 warnings, 0 errors.
- TagReader functional smoke test (synthetic files, run
  locally): ID3v2.4 syncsafe sizes + TIT2 UTF-8 / TPE1
  Latin-1 / TALB UTF-16LE+BOM all decoded; ID3v2.3 UTF-16BE
  title decoded; ID3v1 trailer decoded; filename fallback
  "my_great_song.flac" -> "my great song"; FmtDuration(44100*9
  + 22050) = "0:10" (round-half-away matches JS Math.round).

### Delivered 2026-11-06
All 13 app files written (see app/ listing), App.xaml converters
registered, build-app.cmd at native-win root, NOTES.md Step 2
section appended (decisions + six numbered blind-write risks +
PowerShell build/run commands). Verification: 4 XML files parse;
9 C# files brace-balance; Models+TagReader compiled & smoke-tested
in-VM. Nothing left open in this session. Core untouched
(mtimes: core/ files still 2026-11-06 17:51, pre-session).
