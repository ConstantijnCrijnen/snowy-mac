using System.Numerics;

namespace Snowy.Core;

/// <summary>
/// A bounded, per-monitor snow simulation. Coordinates are monitor-local DIPs, with the
/// origin at the top left. Falling snow, settled caps, and pushed material share one field
/// of mass so the cursor does not turn a pile into disposable particles.
/// </summary>
public sealed class SnowSimulation
{
    private const int MaximumBodies = 512;
    private const int MaximumProfiles = 16_384;
    private const int MaximumFlakes = 160;
    private const float Epsilon = 0.0001f;
    private readonly List<SurfaceState> _surfaces = new(MaximumBodies + 1);
    private readonly List<Flake> _flakes = new(MaximumFlakes);
    private readonly LooseSnowField _looseSnow;
    private readonly List<Body> _bodies = new(MaximumBodies);
    private readonly List<SnowProfile> _profileView = new(MaximumBodies + 1);
    private readonly List<int>[] _surfaceBuckets;
    private readonly List<int>[] _bodyBuckets;
    private readonly List<int> _surfaceCandidates = new(MaximumBodies + 1);
    private readonly List<int> _bodyCandidates = new(MaximumBodies);
    private readonly int[] _surfaceCandidateStamps = new int[MaximumBodies + 1];
    private readonly int[] _bodyCandidateStamps = new int[MaximumBodies];
    private int _surfaceCandidateGeneration;
    private int _bodyCandidateGeneration;
    private Vector2? _previousPointer;
    private Vector2 _wind;
    private float _elapsed;
    private float _settleTimer;
    private uint _randomState = 0x51F15EED;
    private bool _exposureDirty = true;

    public SnowSimulation(int width, int height)
    {
        Width = Math.Clamp(width, 1, 8192);
        Height = Math.Clamp(height, 1, 8192);
        _looseSnow = new LooseSnowField(Width, Height);
        _surfaceBuckets = Enumerable.Range(0, (Width + 63) / 64 + 2).Select(_ => new List<int>()).ToArray();
        _bodyBuckets = Enumerable.Range(0, _surfaceBuckets.Length).Select(_ => new List<int>()).ToArray();
        BuildFloor();
    }

    public int Width { get; }
    public int Height { get; }
    public IReadOnlyList<Flake> Flakes => _flakes;
    public IReadOnlyList<SnowProfile> Profiles => _profileView;
    public IReadOnlyList<SnowCell> LooseCells => _looseSnow.Cells;
    public float LooseCellPitch => _looseSnow.RenderPitch;
    public int ActiveLooseCellCount => _looseSnow.ActiveCount;

    /// <summary>Provide current visible physical supports. Stable IDs preserve their snow when they move.</summary>
    public void SetBodies(IReadOnlyList<Body> bodies)
    {
        ArgumentNullException.ThrowIfNull(bodies);
        var next = new List<Body>(Math.Min(bodies.Count, MaximumBodies));
        var ids = new HashSet<long>();
        foreach (var candidate in bodies)
        {
            if (next.Count == MaximumBodies) break;
            if (!candidate.IsValid || !ids.Add(candidate.Id)) continue;
            var corner = float.IsFinite(candidate.CornerRadius) ? candidate.CornerRadius : 0;
            next.Add(candidate with { CornerRadius = Math.Clamp(corner, 0, MathF.Min(candidate.Size.X, candidate.Size.Y) * 0.5f) });
        }

        var oldById = _bodies.ToDictionary(body => body.Id);
        var newById = next.ToDictionary(body => body.Id);
        var previousSurfaces = _surfaces.ToArray();
        var oldSurfaceById = _surfaces.Where(surface => surface.Body is not null)
            .ToDictionary(surface => surface.Body!.Value.Id);
        var nextSurfaces = new List<SurfaceState>(next.Count + 1);

        foreach (var body in next)
        {
            var count = SampleCount(body.Size.X, next.Count + 1);
            if (oldSurfaceById.TryGetValue(body.Id, out var previous))
            {
                var resized = ResizeSurface(previous, body, count);
                nextSurfaces.Add(resized);
            }
            else
            {
                nextSurfaces.Add(new SurfaceState(body, count, IsFloor: false));
            }
        }

        var floor = _surfaces.FirstOrDefault(surface => surface.IsFloor);
        if (floor is null) floor = new SurfaceState(null, SampleCount(Width, next.Count + 1), IsFloor: true, floorWidth: Width, floorY: Height);
        else if (floor.Heights.Length != SampleCount(Width, next.Count + 1))
            floor = ResizeSurface(floor, null, SampleCount(Width, next.Count + 1), Width, Height);
        nextSurfaces.Add(floor);

        _surfaces.Clear();
        _surfaces.AddRange(nextSurfaces);
        _bodies.Clear();
        _bodies.AddRange(next);
        _looseSnow.SetBodies(_bodies);
        RebuildBodyBuckets();
        RebuildSurfaceBuckets();
        _exposureDirty = true;
        RecomputeExposure();

        // A newly opened rectangle hides just the snow it physically covers.
        foreach (var body in next)
        {
            if (oldById.ContainsKey(body.Id)) continue;
            _looseSnow.Erase(body);
            foreach (var surface in nextSurfaces)
            {
                if (surface.Body?.Id == body.Id) continue;
                RemoveCoveredSnow(surface, body);
            }
        }

        // Snow caught between a moving cap and a lower support is handed to the lower cap.
        // This preserves the visible pile when a window is dragged down over another one.
        foreach (var changedBody in next)
        {
            if (!oldById.TryGetValue(changedBody.Id, out var oldBody) || oldBody == changedBody) continue;
            _looseSnow.Push(oldBody, changedBody);
            var movingSurface = nextSurfaces.First(surface => surface.Body?.Id == changedBody.Id);
            TransferOverlappedCap(movingSurface, changedBody, nextSurfaces);
            PushSnowInBody(movingSurface, oldBody, changedBody, nextSurfaces);
        }

        // Closing a support releases its cap to gravity. A tiny bounded parcel queue keeps
        // mass alive while avoiding unbounded allocations if a large scene is dismissed.
        foreach (var removed in previousSurfaces.Where(surface => surface.Body is not null && !newById.ContainsKey(surface.Body.Value.Id)))
            ReleaseSurface(removed);

        _looseSnow.RefreshRenderView();
        UpdateProfileView();
    }

    /// <summary>
    /// Advance one frame. Wind components are normalized to [-1, 1], with positive Y pointing down.
    /// </summary>
    public void Step(float dt, Snowfall snowfall, Vector2 wind, Vector2? pointer, SnowTool tool, bool reducedMotion)
    {
        if (!float.IsFinite(dt) || dt <= 0) return;
        dt = MathF.Min(dt, 0.05f);
        _looseSnow.BeginFrame();
        var nextWind = FiniteWind(wind);
        if (_wind != nextWind)
        {
            _wind = nextWind;
            _exposureDirty = true;
        }
        _elapsed += dt;
        RecomputeExposure();

        if (pointer is { } current && IsFinite(current))
        {
            var start = _previousPointer ?? current;
            if (_previousPointer is not null || tool == SnowTool.Shovel) Sweep(start, current, tool);
            _previousPointer = current;
        }
        else _previousPointer = null;

        DepositAmbientSnow(dt, snowfall);
        _settleTimer += dt;
        if (_settleTimer >= 0.1f)
        {
            foreach (var surface in _surfaces) surface.Settle();
            _settleTimer %= 0.1f;
        }

        var desiredFlakes = reducedMotion ? 0 : snowfall switch
        {
            Snowfall.Light => 64,
            Snowfall.Steady => 112,
            _ => MaximumFlakes
        };
        while (_flakes.Count > desiredFlakes) _flakes.RemoveAt(_flakes.Count - 1);
        while (_flakes.Count < desiredFlakes) _flakes.Add(NewFlake(scattered: true));
        for (var i = 0; i < _flakes.Count; i++)
            AdvanceFlake(i, dt);

        _looseSnow.Step(dt, _wind, LandGranularSnow);
        UpdateProfileView();
    }

    public void Clear()
    {
        foreach (var surface in _surfaces) Array.Clear(surface.Heights);
        _looseSnow.Clear();
        _previousPointer = null;
        UpdateProfileView();
    }

    public float TotalSettledMass => _surfaces.Sum(surface => surface.Area);
    public float TotalLooseMass => _looseSnow.TotalMass;

    private int SampleCount(float width, int supportCount)
    {
        var budget = Math.Max(5, MaximumProfiles / Math.Max(1, supportCount));
        return Math.Clamp(Math.Min(budget, (int)MathF.Ceiling(width / 4) + 1), 5, 512);
    }

    private void BuildFloor()
    {
        var floor = new SurfaceState(null, SampleCount(Width, 1), IsFloor: true, floorWidth: Width, floorY: Height);
        _surfaces.Add(floor);
        _profileView.Add(floor.ToProfile(Width, Height));
        RebuildSurfaceBuckets();
    }

    private void RebuildBodyBuckets()
    {
        foreach (var bucket in _bodyBuckets) bucket.Clear();
        for (var bodyIndex = 0; bodyIndex < _bodies.Count; bodyIndex++)
        {
            var body = _bodies[bodyIndex];
            var first = BucketFor(body.Left);
            var last = BucketFor(body.Right);
            for (var bucket = first; bucket <= last; bucket++) _bodyBuckets[bucket].Add(bodyIndex);
        }
    }

    private void RebuildSurfaceBuckets()
    {
        foreach (var bucket in _surfaceBuckets) bucket.Clear();
        for (var surfaceIndex = 0; surfaceIndex < _surfaces.Count; surfaceIndex++)
        {
            var surface = _surfaces[surfaceIndex];
            var left = surface.Body?.Left ?? 0;
            var right = left + surface.Width;
            for (var bucket = BucketFor(left); bucket <= BucketFor(right); bucket++)
                _surfaceBuckets[bucket].Add(surfaceIndex);
        }
    }

    private List<int> BodyCandidatesAt(float x) => BodyCandidatesInRange(x, x);

    private List<int> BodyCandidatesInRange(float left, float right)
    {
        _bodyCandidates.Clear();
        if (_bodies.Count == 0) return _bodyCandidates;
        if (++_bodyCandidateGeneration == int.MaxValue)
        {
            Array.Clear(_bodyCandidateStamps);
            _bodyCandidateGeneration = 1;
        }
        for (var bucket = BucketFor(left); bucket <= BucketFor(right); bucket++)
        foreach (var index in _bodyBuckets[bucket])
        {
            if (_bodyCandidateStamps[index] == _bodyCandidateGeneration) continue;
            _bodyCandidateStamps[index] = _bodyCandidateGeneration;
            _bodyCandidates.Add(index);
        }
        return _bodyCandidates;
    }

    private List<int> SurfaceCandidatesInRange(float left, float right)
    {
        _surfaceCandidates.Clear();
        if (++_surfaceCandidateGeneration == int.MaxValue)
        {
            Array.Clear(_surfaceCandidateStamps);
            _surfaceCandidateGeneration = 1;
        }
        for (var bucket = BucketFor(left); bucket <= BucketFor(right); bucket++)
        foreach (var index in _surfaceBuckets[bucket])
        {
            if (_surfaceCandidateStamps[index] == _surfaceCandidateGeneration) continue;
            _surfaceCandidateStamps[index] = _surfaceCandidateGeneration;
            _surfaceCandidates.Add(index);
        }
        return _surfaceCandidates;
    }

    private int BucketFor(float x) => Math.Clamp((int)MathF.Floor(x / 64) + 1, 0, _surfaceBuckets.Length - 1);

    private void UpdateProfileView()
    {
        _profileView.Clear();
        foreach (var surface in _surfaces)
            _profileView.Add(surface.ToProfile(Width, Height));
    }

    private static SurfaceState ResizeSurface(SurfaceState previous, Body? body, int count, float? floorWidth = null, float? floorY = null)
    {
        var resized = new SurfaceState(body, count, previous.IsFloor, floorWidth ?? previous.Width, floorY ?? previous.FloorY);
        var oldWidth = previous.Width;
        var oldMass = previous.Area;
        if (previous.Heights.Length == 1 || oldWidth <= Epsilon) return resized;
        for (var i = 0; i < count; i++)
        {
            var x = resized.Width * i / (count - 1);
            if (x > oldWidth) continue;
            resized.Heights[i] = MathF.Min(resized.Capacity[i], previous.HeightAt(x));
        }
        var newMass = resized.Area;
        if (newMass > oldMass && newMass > Epsilon)
        {
            var scale = oldMass / newMass;
            for (var i = 0; i < count; i++) resized.Heights[i] *= scale;
        }
        return resized;
    }

    private void DepositAmbientSnow(float dt, Snowfall snowfall)
    {
        var rate = snowfall switch { Snowfall.Light => 0.6f, Snowfall.Steady => 1f, _ => 2.1f };
        foreach (var surface in _surfaces)
        {
            for (var i = 0; i < surface.Heights.Length; i++)
            {
                if (!surface.Sky[i] || surface.Shadow[i]) continue;
                var room = surface.SnowCapacity[i] - surface.Heights[i];
                if (room <= 0) continue;
                surface.Heights[i] += MathF.Min(room, surface.Deposition[i] * dt * rate);
            }
        }
    }

    private Flake NewFlake(bool scattered)
    {
        var depth = NextRandom();
        var radius = 0.65f + depth * depth * 1.65f;
        var x = NextRandom() * Width;
        var y = scattered ? NextRandom() * Height : -5;
        for (var attempt = 0; attempt < 4 && BodyCandidatesAt(x).Any(index => _bodies[index].Contains(new Vector2(x, y), radius)); attempt++)
        {
            x = NextRandom() * Width;
            y = -5;
        }
        return new Flake(new Vector2(x, y), radius, 0.3f + depth * 0.55f);
    }

    private void AdvanceFlake(int index, float dt)
    {
        var flake = _flakes[index];
        var phase = (index * 2.3999632f) % (MathF.PI * 2);
        var start = flake.Position;
        var end = start + new Vector2(
            (MathF.Sin(_elapsed * 0.3f + phase) * 8 + _wind.X * 80) * dt,
            (40 + _wind.Y * 20) * dt);

        var obstruction = FirstBodyHit(start, end, flake.Radius);
        var surface = FirstSurfaceHit(start, end, flake.Radius);
        if (surface is { } hitSurface && (obstruction is null || hitSurface.Time <= obstruction.Value.Time))
        {
            hitSurface.Surface.Deposit(hitSurface.X - (hitSurface.Surface.Body?.Left ?? 0), 0.35f * flake.Radius * flake.Radius, snowfall: true, _wind.X);
            _flakes[index] = NewFlake(scattered: false);
        }
        else if (obstruction is not null)
        {
            _flakes[index] = NewFlake(scattered: false);
        }
        else if (end.Y > Height + 5 || end.Y < -40)
        {
            if (end.Y > Height)
                _surfaces.First(surface => surface.IsFloor).Deposit(Math.Clamp(end.X, 0, Width), 0.35f * flake.Radius * flake.Radius, snowfall: true, _wind.X);
            _flakes[index] = NewFlake(scattered: false);
        }
        else
        {
            if (end.X < -5) end.X += Width + 10;
            else if (end.X > Width + 5) end.X -= Width + 10;
            _flakes[index] = flake with { Position = end };
        }
    }

    private (float Time, float X, SurfaceState Surface)? FirstSurfaceHit(Vector2 start, Vector2 end, float radius)
    {
        var delta = end - start;
        if (delta.Y <= 0 && MathF.Abs(delta.X) < Epsilon) return null;
        (float Time, float X, SurfaceState Surface)? first = null;
        var minX = MathF.Min(start.X, end.X);
        var maxX = MathF.Max(start.X, end.X);
        foreach (var surfaceIndex in SurfaceCandidatesInRange(minX, maxX))
        {
            var surface = _surfaces[surfaceIndex];
            var body = surface.Body;
            var left = body?.Left ?? 0;
            var spanLeft = MathF.Max(0, minX - left);
            var spanRight = MathF.Min(surface.Width, maxX - left);
            if (spanLeft > spanRight) continue;
            var begin = Math.Clamp((int)MathF.Floor(spanLeft / surface.Spacing), 0, surface.Heights.Length - 2);
            var finish = Math.Clamp((int)MathF.Ceiling(spanRight / surface.Spacing), begin, surface.Heights.Length - 2);
            for (var i = begin; i <= finish; i++)
            {
                var x0 = i * surface.Spacing;
                var x1 = x0 + surface.Spacing;
                var top0 = surface.BaseY(x0) - surface.Heights[i];
                var top1 = surface.BaseY(x1) - surface.Heights[i + 1];
                var slope = (top1 - top0) / surface.Spacing;
                var approach = delta.Y - slope * delta.X;
                if (approach <= Epsilon) continue;
                var time = (top0 + slope * (start.X - left - x0) - radius - start.Y) / approach;
                if (time < 0 || time > 1 || first is not null && time >= first.Value.Time) continue;
                var hitX = start.X + delta.X * time;
                var local = hitX - left;
                if (local < x0 - 0.001f || local > x1 + 0.001f || !surface.IsExposedAt(local)) continue;
                first = (time, hitX, surface);
            }
        }
        return first;
    }

    private (float Time, Body Body, Vector2 Normal)? FirstBodyHit(Vector2 start, Vector2 end, float radius)
    {
        (float Time, Body Body, Vector2 Normal)? first = null;
        foreach (var bodyIndex in BodyCandidatesInRange(MathF.Min(start.X, end.X) - radius, MathF.Max(start.X, end.X) + radius))
        {
            var body = _bodies[bodyIndex];
            if (MathF.Max(start.X, end.X) + radius < body.Left ||
                MathF.Min(start.X, end.X) - radius > body.Right ||
                MathF.Max(start.Y, end.Y) + radius < body.Top ||
                MathF.Min(start.Y, end.Y) - radius > body.Bottom)
                continue;
            var subdivisions = Math.Clamp((int)MathF.Ceiling(Vector2.Distance(start, end) / MathF.Max(1, radius * 2)), 4, 16);
            for (var sample = 0; sample <= subdivisions; sample++)
            {
                var t = sample / (float)subdivisions;
                var point = Vector2.Lerp(start, end, t);
                if (!body.Contains(point, radius)) continue;
                if (first is null || t < first.Value.Time)
                    first = (t, body, EntryNormal(start, end, point, body));
                break;
            }
        }
        return first;
    }

    private void RecomputeExposure()
    {
        if (!_exposureDirty) return;
        var strength = MathF.Abs(_wind.X);
        var reach = strength * 96;
        foreach (var surface in _surfaces)
        {
            for (var i = 0; i < surface.Heights.Length; i++)
            {
                var local = i * surface.Spacing;
                var x = (surface.Body?.Left ?? 0) + local;
                var baseY = surface.BaseY(local);
                var exposed = x >= 0 && x <= Width && baseY >= 0 && baseY <= Height;
                var sky = exposed;
                var suppression = 1f;
                var boost = 0f;
                var capacityBoost = 0f;
                foreach (var bodyIndex in BodyCandidatesAt(x))
                {
                    var body = _bodies[bodyIndex];
                    if (surface.Body?.Id == body.Id) continue;
                    if (VerticalSpan(body, x) is { } span && span.Top < baseY - 0.01f && span.Bottom > baseY - 20) exposed = false;
                    if (x >= body.Left && x <= body.Right && body.Top < baseY - 0.01f) sky = false;
                    if (strength <= 0 || body.Top >= baseY - 0.5f || body.Bottom < baseY - 28) continue;
                    var contact = Math.Clamp((body.Bottom - baseY + 28) / 28, 0, 1) * Math.Clamp((baseY - body.Top) / 28, 0, 1);
                    if (contact <= 0) continue;
                    var sampleY = Math.Clamp(baseY, body.Top, body.Bottom);
                    var edge = MathF.Min(sampleY - body.Top, body.Bottom - sampleY);
                    var radius = Math.Clamp(body.CornerRadius, 0, MathF.Min(body.Size.X, body.Size.Y) * 0.5f);
                    var inset = edge < radius ? radius - MathF.Sqrt(MathF.Max(0, radius * radius - (radius - edge) * (radius - edge))) : 0;
                    var left = body.Left + inset;
                    var right = body.Right - inset;
                    var side = x <= left ? -1 : x >= right ? 1 : 0;
                    if (side == 0) continue;
                    var distance = side < 0 ? left - x : x - right;
                    var shadowRadius = reach * contact;
                    if (side * _wind.X > 0)
                    {
                        if (distance <= shadowRadius) suppression = 0;
                        else if (distance < shadowRadius + 4) suppression = MathF.Min(suppression, Smooth((distance - shadowRadius) / 4));
                    }
                    else if (distance < shadowRadius)
                    {
                        var shape = Smooth(1 - distance / MathF.Max(0.001f, shadowRadius));
                        boost = MathF.Max(boost, strength * contact * shape * 1.25f);
                        capacityBoost = MathF.Max(capacityBoost, strength * contact * shape * 0.6f);
                    }
                }
                surface.Exposed[i] = exposed;
                surface.Sky[i] = sky && exposed;
                surface.Shadow[i] = suppression <= 0;
                surface.SnowCapacity[i] = MathF.Min(surface.Capacity[i], surface.Capacity[i] * surface.Lobes[i] * (1 + capacityBoost) * suppression);
                var taper = surface.Capacity[i] / (surface.IsFloor ? 28 : 18);
                surface.Deposition[i] = (0.18f + surface.Lobes[i] * 0.17f) * taper * (1 + boost) * suppression;
            }
        }
        _exposureDirty = false;
    }

    private void Sweep(Vector2 start, Vector2 end, SnowTool tool)
    {
        var delta = end - start;
        var travel = delta.Length();
        var hard = tool == SnowTool.Shovel;
        if (!hard && travel < 0.5f) return;
        var radius = hard ? 36f : 24f;
        var strength = hard ? 1f : MathF.Min(0.7f, travel / (radius * 1.2f));
        var lengthSquared = delta.LengthSquared();
        foreach (var surface in _surfaces)
        {
            var left = surface.Body?.Left ?? 0;
            for (var i = 0; i < surface.Heights.Length; i++)
            {
                var height = surface.Heights[i];
                if (height <= Epsilon || !surface.Exposed[i]) continue;
                var local = i * surface.Spacing;
                var baseY = surface.BaseY(local);
                var point = new Vector2(left + local, baseY - height * 0.5f);
                var t = lengthSquared > Epsilon ? Math.Clamp(Vector2.Dot(point - start, delta) / lengthSquared, 0, 1) : 0;
                var closest = start + delta * t;
                var horizontal = point.X - closest.X;
                if (MathF.Abs(horizontal) >= radius) continue;
                var verticalReach = MathF.Sqrt(radius * radius - horizontal * horizontal);
                var overlap = MathF.Max(0, MathF.Min(baseY, closest.Y + verticalReach) - MathF.Max(baseY - height, closest.Y - verticalReach));
                var removed = hard && overlap > 0 ? height : MathF.Min(height, overlap * strength);
                if (removed <= Epsilon) continue;
                var direction = travel > 0.5f ? Vector2.Normalize(delta) : new Vector2(point.X < end.X ? -1 : 1, -0.15f);
                var target = new Vector2(end.X + direction.X * (radius + 4), MathF.Min(point.Y, end.Y + direction.Y * (radius + 4)));
                _looseSnow.Add(removed * surface.Spacing, target, direction, (end, radius));
                surface.Heights[i] -= removed;
            }
        }
        _looseSnow.Brush(start, end, radius, hard);
    }

    private void RemoveCoveredSnow(SurfaceState surface, Body body)
    {
        var left = surface.Body?.Left ?? 0;
        for (var i = 0; i < surface.Heights.Length; i++)
        {
            var height = surface.Heights[i];
            if (height <= 0) continue;
            var x = left + i * surface.Spacing;
            var baseY = surface.BaseY(i * surface.Spacing);
            var bodySpan = VerticalSpan(body, x);
            if (bodySpan is not { } span) continue;
            var overlap = MathF.Max(0, MathF.Min(baseY, span.Bottom) - MathF.Max(baseY - height, span.Top));
            surface.Heights[i] = MathF.Max(0, height - overlap);
        }
    }

    private void TransferOverlappedCap(SurfaceState moved, Body newBody, List<SurfaceState> surfaces)
    {
        foreach (var receiver in surfaces)
        {
            if (receiver == moved) continue;
            var receiverLeft = receiver.Body?.Left ?? 0;
            for (var i = 0; i < moved.Heights.Length; i++)
            {
                var height = moved.Heights[i];
                if (height <= Epsilon) continue;
                var x = newBody.Left + i * moved.Spacing;
                var baseY = newBody.SurfaceY(x);
                var receiveLocal = x - receiverLeft;
                if (receiveLocal < 0 || receiveLocal > receiver.Width) continue;
                var receiveY = receiver.BaseY(receiveLocal);
                if (receiveY < baseY - height || receiveY >= baseY) continue;
                var overlap = MathF.Max(0, MathF.Min(height, baseY - receiveY));
                if (overlap <= 0) continue;
                var transferredMass = overlap * moved.Spacing;
                var remainder = receiver.Deposit(receiveLocal, transferredMass, snowfall: false, _wind.X);
                var transferredHeight = (transferredMass - remainder) / moved.Spacing;
                moved.Heights[i] = MathF.Max(0, moved.Heights[i] - transferredHeight);
            }
        }
    }

    private void PushSnowInBody(SurfaceState moved, Body oldBody, Body newBody, List<SurfaceState> surfaces)
    {
        var direction = LeadingFaceDirection(oldBody, newBody);
        const float padding = 4f;
        foreach (var surface in surfaces)
        {
            if (surface == moved) continue;
            var left = surface.Body?.Left ?? 0;
            for (var i = 0; i < surface.Heights.Length; i++)
            {
                var height = surface.Heights[i];
                if (height <= Epsilon) continue;
                var local = i * surface.Spacing;
                var point = new Vector2(left + local, surface.BaseY(local) - height * 0.5f);
                if (!newBody.Contains(point)) continue;
                var target = direction.X < 0
                    ? new Vector2(newBody.Left - padding, point.Y)
                    : direction.X > 0
                        ? new Vector2(newBody.Right + padding, point.Y)
                        : direction.Y < 0
                            ? new Vector2(point.X, newBody.Top - padding)
                            : new Vector2(point.X, newBody.Bottom + padding);
                _looseSnow.Add(height * surface.Spacing, target, direction + _wind * 0.25f);
                surface.Heights[i] = 0;
            }
        }
    }

    private void ReleaseSurface(SurfaceState surface)
    {
        var left = surface.Body?.Left ?? 0;
        for (var i = 0; i < surface.Heights.Length; i++)
        {
            var height = surface.Heights[i];
            if (height <= Epsilon) continue;
            var local = i * surface.Spacing;
            var point = new Vector2(left + local, Math.Clamp(surface.BaseY(local) - height * 0.5f,
                _looseSnow.CellSize * 0.5f, Height - _looseSnow.CellSize * 0.5f));
            _looseSnow.Add(height * surface.Spacing, point, new Vector2(_wind.X, 1));
            surface.Heights[i] = 0;
        }
    }

    private (float Remaining, bool Blocked) LandGranularSnow(Vector2 start, Vector2 end, float mass)
    {
        var radius = _looseSnow.CellSize * 0.45f;
        var hit = FirstSurfaceHit(start, end, radius);
        if (hit is not { } contact) return (mass, false);
        var local = contact.X - (contact.Surface.Body?.Left ?? 0);
        var remaining = contact.Surface.Deposit(local, mass, snowfall: false, _wind.X);
        return (remaining, true);
    }

    private static Vector2 LeadingFaceDirection(Body oldBody, Body newBody)
    {
        var dx = newBody.Left - oldBody.Left;
        var dy = newBody.Top - oldBody.Top;
        if (MathF.Abs(dx) > 0.01f || MathF.Abs(dy) > 0.01f)
            return MathF.Abs(dx) >= MathF.Abs(dy)
                ? new Vector2(MathF.Sign(dx), 0)
                : new Vector2(0, MathF.Sign(dy));

        var expansion = new[]
        {
            oldBody.Left - newBody.Left,
            newBody.Right - oldBody.Right,
            oldBody.Top - newBody.Top,
            newBody.Bottom - oldBody.Bottom
        };
        var face = Array.IndexOf(expansion, expansion.Max());
        return face switch
        {
            0 => new Vector2(-1, 0),
            1 => new Vector2(1, 0),
            2 => new Vector2(0, -1),
            3 => new Vector2(0, 1),
            _ => Vector2.UnitX
        };
    }

    private static Vector2 EntryNormal(Vector2 start, Vector2 end, Vector2 contact, Body body)
    {
        if (start.X <= body.Left) return new Vector2(-1, 0);
        if (start.X >= body.Right) return Vector2.UnitX;
        if (start.Y <= body.Top) return new Vector2(0, -1);
        if (start.Y >= body.Bottom) return Vector2.UnitY;
        var motion = end - start;
        if (MathF.Abs(motion.X) > MathF.Abs(motion.Y))
            return new Vector2(start.X < (body.Left + body.Right) * 0.5f ? -1 : 1, 0);
        return new Vector2(0, start.Y < (body.Top + body.Bottom) * 0.5f ? -1 : 1);
    }

    private static (float Top, float Bottom)? VerticalSpan(Body body, float x)
    {
        var radius = body.CornerRadius;
        if (x < body.Left || x > body.Right) return null;
        var edge = MathF.Min(x - body.Left, body.Right - x);
        var inset = edge < radius && radius > 0 ? radius - MathF.Sqrt(MathF.Max(0, radius * radius - (radius - edge) * (radius - edge))) : 0;
        return (body.Top + inset, body.Bottom - inset);
    }

    private static float Smooth(float value)
    {
        value = Math.Clamp(value, 0, 1);
        return value * value * (3 - 2 * value);
    }

    private static Vector2 FiniteWind(Vector2 wind)
    {
        if (!IsFinite(wind)) return Vector2.Zero;
        return Vector2.Clamp(wind, new Vector2(-1), new Vector2(1));
    }

    private static bool IsFinite(Vector2 value) => float.IsFinite(value.X) && float.IsFinite(value.Y);

    private float NextRandom()
    {
        var value = _randomState;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        _randomState = value == 0 ? 0x51F15EED : value;
        return _randomState / (float)uint.MaxValue;
    }

    private sealed class SurfaceState
    {
        public SurfaceState(Body? body, int count, bool IsFloor, float floorWidth = 1, float floorY = 0)
        {
            Body = body;
            this.IsFloor = IsFloor;
            FloorY = floorY;
            var width = IsFloor ? floorWidth : body?.Size.X ?? 1;
            Spacing = width / (count - 1);
            Width = width;
            Heights = new float[count];
            Capacity = new float[count];
            SnowCapacity = new float[count];
            Deposition = new float[count];
            Lobes = new float[count];
            Sky = new bool[count];
            Exposed = new bool[count];
            Shadow = new bool[count];
            if (IsFloor)
            {
                Array.Fill(Exposed, true);
                Array.Fill(Sky, true);
            }
            for (var i = 0; i < count; i++)
            {
                var x = i * Spacing;
                var limit = IsFloor ? 28f : body?.Kind == BodyKind.Taskbar ? 13f : 18f;
                var taper = IsFloor ? 1 : Smooth(MathF.Min(1, MathF.Min(x, width - x) / 13));
                // Reduce IDs before float conversion. Synthetic taskbar/decoration IDs are
                // intentionally large; converting them directly erased the x-dependent lobes.
                var phase = body is null ? 0 : (float)(((body.Value.Id % 4096) + 4096) % 4096) * 0.17f;
                var lobe = 0.68f + MathF.Sin(x * 0.027f + phase) * 0.18f + MathF.Sin(x * 0.071f + phase * 2) * 0.09f + MathF.Sin(x * 0.13f + phase) * 0.05f;
                Lobes[i] = lobe;
                Capacity[i] = limit * taper;
                SnowCapacity[i] = Capacity[i] * lobe;
                Deposition[i] = (0.18f + lobe * 0.17f) * taper;
            }
        }

        public Body? Body { get; }
        public bool IsFloor { get; }
        public float FloorY { get; }
        public float Width { get; }
        public float Spacing { get; private set; }
        public float[] Heights { get; }
        public float[] Capacity { get; }
        public float[] SnowCapacity { get; }
        public float[] Deposition { get; }
        public float[] Lobes { get; }
        public bool[] Sky { get; }
        public bool[] Exposed { get; }
        public bool[] Shadow { get; }
        public float Area => Heights.Sum() * Spacing;

        public float BaseY(float local)
        {
            if (IsFloor) return FloorY;
            var body = Body!.Value;
            var radius = body.CornerRadius;
            var edge = MathF.Max(0, MathF.Min(local, body.Size.X - local));
            if (edge >= radius || radius <= 0) return body.Top;
            var inset = radius - edge;
            return body.Top + radius - MathF.Sqrt(MathF.Max(0, radius * radius - inset * inset));
        }

        public float HeightAt(float local)
        {
            if (local < 0 || local > Width || Heights.Length < 2) return 0;
            var coordinate = local / Spacing;
            var index = Math.Clamp((int)MathF.Floor(coordinate), 0, Heights.Length - 2);
            return Heights[index] + (Heights[index + 1] - Heights[index]) * (coordinate - index);
        }

        public bool IsExposedAt(float local)
        {
            var index = Math.Clamp((int)MathF.Round(local / Spacing), 0, Exposed.Length - 1);
            return Exposed[index];
        }

        public float Deposit(float local, float mass, bool snowfall, float direction)
        {
            if (!float.IsFinite(local) || !float.IsFinite(mass) || mass <= 0 || local < 0 || local > Width) return MathF.Max(0, mass);
            var center = Math.Clamp(direction > 0 ? (int)MathF.Ceiling(local / Spacing) : direction < 0 ? (int)MathF.Floor(local / Spacing) : (int)MathF.Round(local / Spacing), 0, Heights.Length - 1);
            var remaining = mass;
            for (var distance = 0; distance < Heights.Length && remaining > Epsilon; distance++)
            {
                var visitedA = center + (direction < 0 ? -distance : distance);
                remaining = Fill(visitedA, remaining, snowfall);
                if (direction == 0 && distance > 0 && remaining > Epsilon)
                    remaining = Fill(center - distance, remaining, snowfall);
            }
            return remaining <= Epsilon ? 0 : remaining;
        }

        private float Fill(int index, float amount, bool snowfall)
        {
            if (index < 0 || index >= Heights.Length || !Exposed[index] || snowfall && (!Sky[index] || Shadow[index])) return amount;
            var limit = snowfall ? SnowCapacity[index] : Capacity[index];
            var accepted = MathF.Min(amount, MathF.Max(0, limit - Heights[index]) * Spacing);
            Heights[index] += accepted / Spacing;
            return amount - accepted;
        }

        public void Settle()
        {
            for (var i = 0; i < Heights.Length - 1; i++)
            {
                if (!Exposed[i] || !Exposed[i + 1]) continue;
                var from = Heights[i] > Heights[i + 1] ? i : i + 1;
                var to = from == i ? i + 1 : i;
                var transfer = MathF.Min(MathF.Abs(Heights[i] - Heights[i + 1]) * 0.12f,
                    MathF.Min(Heights[from], MathF.Max(0, Capacity[to] - Heights[to])));
                Heights[from] -= transfer;
                Heights[to] += transfer;
            }
        }

        public SnowProfile ToProfile(float screenWidth, float screenHeight)
        {
            var x = Body?.Left ?? 0;
            var y = IsFloor ? screenHeight : Body!.Value.Top;
            var spacing = IsFloor ? screenWidth / (Heights.Length - 1) : Spacing;
            return new SnowProfile(x, y, spacing, Heights) { Id = Body?.Id ?? long.MinValue };
        }
    }
}
