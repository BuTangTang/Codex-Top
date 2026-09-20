using System.Diagnostics;
using System.Windows.Media.Animation;
using CodexTop.Core;

namespace CodexTop.Windows;

// Observe transitions in selected root tasks, not redraws or historical selection.
internal sealed class OrbCompletionTracker
{
    private Dictionary<string, Phase> previous = [];
    private string? source;
    public HashSet<string> Observe(string root, IReadOnlyList<TaskRow> rows, bool reliable)
    {
        if (!reliable) { previous.Clear(); source = null; return []; }
        HashSet<string> completed = [];
        bool sameSource = string.Equals(source, root, StringComparison.OrdinalIgnoreCase);
        foreach (var row in rows)
            if (sameSource && row.Activity.Phase == Phase.Completed && previous.TryGetValue(row.Root.Id, out var before) && before.IsActive()) completed.Add(row.Root.Id);
        previous = rows.ToDictionary(r => r.Root.Id, r => r.Activity.Phase); source = root;
        return completed;
    }
}

internal sealed class CompletionMark : FrameworkElement
{
    public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(nameof(Progress), typeof(double), typeof(CompletionMark), new FrameworkPropertyMetadata(1d, FrameworkPropertyMetadataOptions.AffectsRender));
    public double Progress { get => (double)GetValue(ProgressProperty); set => SetValue(ProgressProperty, value); }
    public long? Cue { get; }
    public CompletionMark(bool animate, TimeSpan age, long? cue, double minimumProgress)
    {
        Cue = cue;
        Width = Height = 32; IsHitTestVisible = false;
        HorizontalAlignment = HorizontalAlignment.Center; VerticalAlignment = VerticalAlignment.Center;
        const double duration = 650;
        var created = Stopwatch.GetTimestamp();
        Progress = animate ? Math.Clamp(Math.Max(minimumProgress, age.TotalMilliseconds / duration), 0, 1) : 1;
        Loaded += (_, _) =>
        {
            if (!animate) return;
            var elapsed = age + Stopwatch.GetElapsedTime(created);
            Progress = Math.Clamp(Math.Max(Progress, elapsed.TotalMilliseconds / duration), 0, 1);
            if (Progress < 1) BeginAnimation(ProgressProperty, new DoubleAnimation(Progress, 1, TimeSpan.FromMilliseconds(duration * (1 - Progress))));
        };
        Unloaded += (_, _) => BeginAnimation(ProgressProperty, null);
    }
    protected override void OnRender(DrawingContext dc)
    {
        double p = Math.Clamp(Progress, 0, 1), reveal = 1 - Math.Pow(1 - p, 3);
        if (p <= 0) return;
        // A brief inner halo and check rebound fit inside the existing 44 DIP orb.
        if (p < 1)
        {
            dc.PushOpacity(.28 * Math.Sin(Math.PI * p));
            dc.DrawEllipse(null, new Pen(Ui.Green, 1.4), new(16, 16), 11 + 4 * p, 11 + 4 * p);
            dc.Pop();
        }
        double scale = 1 - .2 * (1 - reveal) + .08 * Math.Sin(Math.PI * p);
        dc.PushTransform(new ScaleTransform(scale, scale, 16, 16));
        Point start = new(8, 16), elbow = new(14, 22), end = new(25, 9);
        double first = (elbow - start).Length, second = (end - elbow).Length, length = (first + second) * reveal;
        var pen = new Pen(Ui.Green, 2.4) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        dc.DrawLine(pen, start, start + (elbow - start) * Math.Min(1, length / first));
        if (length > first) dc.DrawLine(pen, elbow, elbow + (end - elbow) * Math.Min(1, (length - first) / second));
        dc.Pop();
    }
}
