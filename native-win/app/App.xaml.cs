// App.xaml.cs — the app entry point: one window, titled as
// the Mac app's WindowGroup is ("DiscWright — ATRAC3+ CD ISO
// maker"). Standard unpackaged WinUI 3 launch; the XAML
// compiler generates the real Main, this is OnLaunched only.

using Microsoft.UI.Xaml;

namespace DiscWright;

public partial class App : Application
{
    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }

    private Window? _window;
}
