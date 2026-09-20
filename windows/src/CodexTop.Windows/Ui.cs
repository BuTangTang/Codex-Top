using System.Windows.Automation;
using System.Windows.Controls.Primitives;
using System.Windows.Media.Animation;
using CodexTop.Core;

namespace CodexTop.Windows;

internal static class Ui
{
    public static readonly SolidColorBrush Blue = Brush("#579EFF"), Orange = Brush("#E86E0F"), Red = Brush("#F0646B"), Green = Brush("#65CE98");
    public static SolidColorBrush Brush(string hex) => new((Color)ColorConverter.ConvertFromString(hex));
    public static Brush Fore(bool dark) => dark ? Brush("#F5F5F7") : Brush("#222226");
    public static Brush Muted(bool dark) => dark ? Brush("#9B9BA2") : Brush("#6C6C73");
    public static Brush Status(Phase phase, bool dark) => phase switch { Phase.Running => Blue, Phase.Waiting => dark ? Brush("#F3B850") : Orange, Phase.Failed => Red, Phase.Completed => Green, _ => Muted(dark) };
    public static TextBlock Text(string text, double size, bool dark, bool secondary = false)
    {
        var label = new TextBlock { Text = text, FontSize = size, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        label.SetResourceReference(TextBlock.ForegroundProperty, secondary ? "MutedBrush" : "TextBrush");
        return label;
    }
    public static Button Button(string text, string label, bool dark, Action action, double width = double.NaN)
    {
        var button = new Button { Content = text, ToolTip = label, Foreground = Fore(dark), Background = Brushes.Transparent, BorderThickness = new(0), Padding = new(9, 5, 9, 5), MinHeight = 30, FontSize = 15, Cursor = Cursors.Hand, Width = width };
        AutomationProperties.SetName(button, label);
        button.SetResourceReference(Control.ForegroundProperty, "TextBrush");
        var factory = new FrameworkElementFactory(typeof(Border)); factory.SetValue(Border.CornerRadiusProperty, new CornerRadius(7));
        factory.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = new(System.Windows.Data.RelativeSourceMode.TemplatedParent) });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter)); presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center); presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center); factory.AppendChild(presenter);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = factory };
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true }; hover.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension("HoverBrush"))); template.Triggers.Add(hover);
        var focused = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true }; focused.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension("SelectedBrush"))); template.Triggers.Add(focused);
        button.Template = template; button.Click += (_, _) => action(); return button;
    }
    public static void SetThemeResources(FrameworkElement element, bool dark)
    {
        var resources = element.Resources;
        if (!resources.Contains("CodexControlsLoaded"))
        {
            resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/CodexTop;component/Themes/Controls.xaml", UriKind.Relative) });
            resources["CodexControlsLoaded"] = true;
        }
        if (resources["CodexDark"] is bool applied && applied == dark) return;
        resources["CodexDark"] = dark;
        resources["TextBrush"] = Fore(dark); resources["MutedBrush"] = Muted(dark);
        resources["SurfaceBrush"] = Brush(dark ? "#242426" : "#FAFAFC");
        resources["WindowBrush"] = Brush(dark ? "#171719" : "#F5F5F7");
        resources["ControlBrush"] = Brush(dark ? "#2C2C30" : "#FFFFFF");
        resources["StrokeBrush"] = Brush(dark ? "#45454B" : "#DEDEE5");
        resources["HoverBrush"] = Brush(dark ? "#39393F" : "#EBEBF0");
        resources["SelectedBrush"] = Brush(dark ? "#293C55" : "#E0ECFC");
        resources["AccentBrush"] = Blue;
    }
    public static void ApplyWindowTheme(Window window, bool dark)
    {
        bool first = !window.Resources.Contains("CodexControlsLoaded");
        if (!first && window.Resources["CodexDark"] is bool applied && applied == dark) return;
        SetThemeResources(window, dark);
        window.SetResourceReference(Control.BackgroundProperty, "WindowBrush");
        window.SetResourceReference(Control.ForegroundProperty, "TextBrush");
        window.FontFamily = new("Microsoft YaHei UI"); window.FontSize = 13;
        if (first) window.SourceInitialized += (_, _) => NativeWindow.StyleDialog(window, (bool)window.Resources["CodexDark"]);
        NativeWindow.StyleDialog(window, dark);
    }
}

internal sealed class RunningRing : FrameworkElement
{
    private static readonly System.Diagnostics.Stopwatch Epoch = System.Diagnostics.Stopwatch.StartNew();
    private readonly RotateTransform rotate = new();
    private readonly DrawingVisual drawing = new();
    private Phase phase; private bool dark, animated;
    public RunningRing(double size, Phase phase, bool dark, bool animate)
    {
        Width = Height = size; this.phase = phase; this.dark = dark; animated = animate;
        AddVisualChild(drawing); AddLogicalChild(drawing);
        Loaded += (_, _) => Render(); Unloaded += (_, _) => rotate.BeginAnimation(RotateTransform.AngleProperty, null);
    }
    protected override int VisualChildrenCount => 1;
    protected override Visual GetVisualChild(int index) => drawing;
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    { base.OnDpiChanged(oldDpi, newDpi); Render(); }
    public void Update(Phase phase, bool dark, bool animate)
    { if (this.phase == phase && this.dark == dark && animated == animate) return; this.phase = phase; this.dark = dark; animated = animate; Render(); }
    private void Render()
    {
        using var dc = drawing.RenderOpen(); double center = Width / 2, radius = center - 2;
        rotate.CenterX = rotate.CenterY = center; drawing.Transform = rotate;
        dc.DrawEllipse(null, new Pen(dark ? Ui.Brush("#36363A") : Ui.Brush("#DDDEE2"), Width > 30 ? 1.7 : 2.2), new(center, center), radius, radius);
        if (phase == Phase.Running)
        {
            var path = new StreamGeometry();
            using (var geo = path.Open())
            {
                geo.BeginFigure(new(center, center - radius), false, false);
                geo.ArcTo(new(center - radius, center), new(radius, radius), 0, true, SweepDirection.Clockwise, true, false);
            }
            dc.DrawGeometry(null, new Pen(Ui.Blue, Width > 30 ? 1.8 : 2.4) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, path);
            if (animated)
            {
                double angle = Epoch.Elapsed.TotalSeconds % 1.2 / 1.2 * 360;
                rotate.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(angle, angle + 360, TimeSpan.FromSeconds(1.2)) { RepeatBehavior = RepeatBehavior.Forever });
            }
            else { rotate.BeginAnimation(RotateTransform.AngleProperty, null); rotate.Angle = 0; }
        }
        else
        {
            rotate.BeginAnimation(RotateTransform.AngleProperty, null); rotate.Angle = 0;
            if (phase is Phase.Waiting or Phase.Failed or Phase.Completed) dc.DrawEllipse(null, new Pen(Ui.Status(phase, dark), 1.8), new(center, center), radius, radius);
        }
    }
}
