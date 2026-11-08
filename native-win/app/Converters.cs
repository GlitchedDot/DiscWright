// Converters.cs — the two boolean <-> Visibility converters
// the XAML needs (WinUI ships none). Used for the imported
// mode's read-only rules: row buttons hide on imported tracks,
// the Clear-import button shows only while a disc is imported.

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace DiscWright;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        value is Visibility.Visible;
}

public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        value is Visibility.Collapsed;
}
