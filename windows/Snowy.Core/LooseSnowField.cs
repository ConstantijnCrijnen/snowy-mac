using System.Numerics;

namespace Snowy.Core;

/// <summary>
/// Bounded cellular transport for displaced snow. Each cell stores snow area, not a flying
/// parcel. The active list and fixed per-frame work limits keep the cost independent of the
/// number of empty pixels on the desktop.
/// </summary>
internal sealed class LooseSnowField
{
    private const int MaximumCells = 131_072;
    private const int MaximumActive = 32_768;
    private const int MaximumSearch = 768;
    private const int MaximumVisitsPerFrame = 65_536;
    private const float Epsilon = 0.0001f;

    private readonly float _cellSize;
    private float[] _mass;
    private float[] _output;
    private readonly float[] _incoming;
    private readonly float[] _capacity;
    private readonly bool[] _solid;
    private readonly bool[] _listed;
    private readonly uint[] _visited;
    private readonly int[] _queue;
    private readonly int[] _difference;
    private List<int> _active = new(MaximumActive);
    private List<int> _nextActive = new(MaximumActive);
    private readonly List<int> _affected = new(MaximumActive);
    private readonly List<float> _affectedMass = new(MaximumActive);
    private readonly List<Vector2> _targets = new(MaximumActive);
    private readonly List<SnowCell> _renderCells = new(4096);
    private readonly float[] _renderMass = new float[4096];
    private readonly float[] _renderCapacity = new float[4096];
    private readonly List<Body> _bodies = new(512);
    private readonly float _width;
    private readonly float _height;
    private readonly int _gridColumns;
    private readonly int _gridRows;
    private float _accumulator;
    private float _windDistance;
    private float _pendingMass;
    private Vector2 _pendingPosition;
    private float _renderPitch;
    private int _placementVisits;
    private uint _visitGeneration;
    private ulong _tick;
    private IReadOnlyList<SnowCell> _renderView = Array.Empty<SnowCell>();

    public LooseSnowField(int width, int height)
    {
        _width = width;
        _height = height;
        var finalPitch = MathF.Max(3, MathF.Sqrt((float)width * height / MaximumCells));
        var finalColumns = Math.Max(1, (int)MathF.Ceiling(width / finalPitch));
        var finalRows = Math.Max(1, (int)MathF.Ceiling(height / finalPitch));
        while ((long)finalColumns * finalRows > MaximumCells)
        {
            finalPitch *= MathF.Max(1.005f, MathF.Sqrt((float)((long)finalColumns * finalRows) / MaximumCells));
            finalColumns = Math.Max(1, (int)MathF.Ceiling(width / finalPitch));
            finalRows = Math.Max(1, (int)MathF.Ceiling(height / finalPitch));
        }
        _gridColumns = finalColumns;
        _gridRows = finalRows;
        _cellSize = finalPitch;
        var count = finalColumns * finalRows;
        _mass = new float[count];
        _output = new float[count];
        _incoming = new float[count];
        _capacity = new float[count];
        _solid = new bool[count];
        _listed = new bool[count];
        _visited = new uint[count];
        _queue = new int[Math.Min(count, MaximumSearch)];
        _difference = new int[finalRows * (finalColumns + 1)];
        for (var row = 0; row < finalRows; row++)
        for (var column = 0; column < finalColumns; column++)
        {
            var cellWidth = MathF.Min(finalPitch, width - column * finalPitch);
            var cellHeight = MathF.Min(finalPitch, height - row * finalPitch);
            _capacity[row * finalColumns + column] = cellWidth * cellHeight;
        }
        _placementVisits = MaximumVisitsPerFrame;
    }

    public float CellSize => _cellSize;
    public float RenderPitch => _renderPitch > 0 ? _renderPitch : _cellSize;
    public int ActiveCount => _active.Count;
    public float TotalMass => _pendingMass + _active.Sum(index => _mass[index]);
    public IReadOnlyList<SnowCell> Cells => _renderView;
    public void RefreshRenderView() => BuildRenderView();

    public void Clear()
    {
        foreach (var index in _active)
        {
            _mass[index] = 0;
            _listed[index] = false;
        }
        _active.Clear();
        _nextActive.Clear();
        _pendingMass = 0;
        _accumulator = 0;
        _windDistance = 0;
        _renderView = Array.Empty<SnowCell>();
    }

    public void SetBodies(IReadOnlyList<Body> bodies)
    {
        if (_bodies.SequenceEqual(bodies)) return;
        _placementVisits = MaximumVisitsPerFrame;
        _bodies.Clear();
        for (var i = 0; i < bodies.Count && i < 512; i++) _bodies.Add(bodies[i]);
        Array.Clear(_difference);
        for (var bodyIndex = 0; bodyIndex < _bodies.Count; bodyIndex++)
        {
            var body = _bodies[bodyIndex];
            var firstRow = Math.Max(0, (int)MathF.Ceiling(body.Top / _cellSize - 0.5f));
            var lastRow = Math.Min(_gridRows - 1, (int)MathF.Floor(body.Bottom / _cellSize - 0.5f));
            if (firstRow > lastRow) continue;
            var radius = Math.Clamp(body.CornerRadius, 0, MathF.Min(body.Size.X, body.Size.Y) * 0.5f);
            for (var row = firstRow; row <= lastRow; row++)
            {
                var y = MathF.Min(_height, (row + 0.5f) * _cellSize);
                var edge = MathF.Min(y - body.Top, body.Bottom - y);
                var inset = edge < radius && radius > 0
                    ? radius - MathF.Sqrt(MathF.Max(0, radius * radius - (radius - edge) * (radius - edge))) : 0;
                var left = Math.Max(0, (int)MathF.Ceiling((body.Left + inset) / _cellSize - 0.5f));
                var right = Math.Min(_gridColumns - 1, (int)MathF.Floor((body.Right - inset) / _cellSize - 0.5f));
                if (left > right) continue;
                var offset = row * (_gridColumns + 1);
                _difference[offset + left]++;
                _difference[offset + right + 1]--;
            }
        }
        for (var row = 0; row < _gridRows; row++)
        {
            var coverage = 0;
            var offset = row * (_gridColumns + 1);
            for (var column = 0; column < _gridColumns; column++)
            {
                coverage += _difference[offset + column];
                _solid[row * _gridColumns + column] = coverage > 0;
            }
        }
        _placementVisits = MaximumVisitsPerFrame;
    }

    public void Erase(Body body)
    {
        for (var i = _active.Count - 1; i >= 0; i--)
        {
            var index = _active[i];
            if (!body.Contains(Position(index))) continue;
            _mass[index] = 0;
            _listed[index] = false;
            _active.RemoveAt(i);
        }
    }

    public void BeginFrame() => _placementVisits = MaximumVisitsPerFrame;

    public void Add(float amount, Vector2 point, Vector2 direction = default, (Vector2 Center, float Radius)? excludedCircle = null)
    {
        if (!float.IsFinite(amount) || amount <= Epsilon || !IsFinite(point)) return;
        point = ClampPoint(point);
        var rest = Place(amount, point, direction, excludedCircle);
        if (rest > Epsilon) Retain(rest, point);
    }

    public void Push(Body oldBody, Body newBody)
    {
        var delta = newBody.Position - oldBody.Position;
        var direction = MathF.Abs(delta.X) >= MathF.Abs(delta.Y)
            ? new Vector2(MathF.Sign(delta.X), 0) : new Vector2(0, MathF.Sign(delta.Y));
        if (direction.LengthSquared() < 0.5f)
        {
            var expansion = new[] { oldBody.Left - newBody.Left, newBody.Right - oldBody.Right,
                oldBody.Top - newBody.Top, newBody.Bottom - oldBody.Bottom };
            var side = Array.IndexOf(expansion, expansion.Max());
            direction = side switch { 0 => -Vector2.UnitX, 1 => Vector2.UnitX, 2 => -Vector2.UnitY, _ => Vector2.UnitY };
        }
        _affected.Clear(); _affectedMass.Clear(); _targets.Clear();
        foreach (var index in _active)
        {
            var point = Position(index);
            var swept = oldBody.Contains(point) || newBody.Contains(point) || SweptContains(oldBody, newBody, point);
            if (!swept) continue;
            _affected.Add(index);
            _affectedMass.Add(_mass[index]);
            var target = point;
            if (MathF.Abs(direction.X) >= MathF.Abs(direction.Y))
                target.X = direction.X >= 0 ? newBody.Right + _cellSize : newBody.Left - _cellSize;
            else
                target.Y = direction.Y >= 0 ? newBody.Bottom + _cellSize : newBody.Top - _cellSize;
            _targets.Add(ClampPoint(target));
        }
        Displace(direction, null);
    }

    public void Brush(Vector2 start, Vector2 end, float radius, bool shovel)
    {
        var delta = end - start;
        var travel = delta.Length();
        if (!IsFinite(start) || !IsFinite(end) || !float.IsFinite(radius) || (!shovel && travel < 0.5f)) return;
        radius = Math.Clamp(radius, 1, 128);
        var baseDirection = travel > 0.01f ? Vector2.Normalize(delta) : Vector2.UnitY;
        _affected.Clear(); _affectedMass.Clear(); _targets.Clear();
        foreach (var index in _active)
        {
            var point = Position(index);
            var nearest = ClosestPoint(point, start, end);
            var distance = Vector2.Distance(point, nearest);
            if (distance >= radius + (shovel ? _cellSize * 0.35f : 0)) continue;
            var fraction = shovel ? 1 : MathF.Min(0.65f, travel / MathF.Max(1, radius)) * MathF.Max(0, 1 - distance / radius);
            var moved = _mass[index] * fraction;
            if (moved <= Epsilon) continue;
            var direction = baseDirection;
            var radial = point - end;
            if (radial.LengthSquared() > 0.01f) direction = Vector2.Normalize(direction + Vector2.Normalize(radial) * 0.25f);
            var target = end + direction * (radius + _cellSize);
            _affected.Add(index); _affectedMass.Add(moved); _targets.Add(LastFreePoint(point, target));
        }
        Displace(baseDirection, (end, radius));
    }

    public void Step(float dt, Vector2 wind, Func<Vector2, Vector2, float, (float Remaining, bool Blocked)> landing)
    {
        if (dt <= 0 || !float.IsFinite(dt)) { BuildRenderView(); return; }
        if (_active.Count == 0)
        {
            RetryPending(wind);
            BuildRenderView();
            return;
        }
        _accumulator += MathF.Min(dt, 0.05f);
        const float fixedStep = 1f / 60;
        var steps = Math.Min(3, (int)((_accumulator + 0.000001f) / fixedStep));
        if (steps == 0) { BuildRenderView(); return; }
        _accumulator = Math.Clamp(_accumulator - steps * fixedStep, 0, fixedStep);
        for (var step = 0; step < steps; step++)
        {
            var windDistance = Math.Clamp(wind.X, -1, 1) * 100 * fixedStep / _cellSize + _windDistance;
            var windSide = MathF.Abs(windDistance) >= 1 ? Math.Sign(windDistance) : 0;
            _windDistance = windDistance - windSide;
            CellularStep(windSide, landing);
        }
        RetryPending(wind);
        BuildRenderView();
    }

    private void RetryPending(Vector2 wind)
    {
        if (_pendingMass <= Epsilon) return;
        var pending = _pendingMass;
        var position = _pendingPosition;
        _pendingMass = 0;
        var rest = Place(pending, position, wind, null);
        if (rest > Epsilon) Retain(rest, position);
    }

    private void CellularStep(int windSide, Func<Vector2, Vector2, float, (float Remaining, bool Blocked)> landing)
    {
        _nextActive.Clear();
        for (var offset = 0; offset < _active.Count; offset++)
        {
            var index = _active[offset];
            var remaining = _mass[index];
            if (remaining <= Epsilon) continue;
            var column = index % _gridColumns;
            var row = index / _gridColumns;
            var start = Position(index);
            var side = windSide != 0 ? windSide : (((_tick + (ulong)column) & 1) == 0 ? -1 : 1);
            for (var attempt = 0; attempt < 3 && remaining > Epsilon; attempt++)
            {
                var dx = attempt switch
                {
                    0 => windSide == 0 ? 0 : side,
                    1 => windSide == 0 ? side : 0,
                    _ => -side
                };
                var targetColumn = column + dx;
                if (dx != 0 && (targetColumn < 0 || targetColumn >= _gridColumns)) continue;
                if (dx != 0 && (_solid[row * _gridColumns + targetColumn] ||
                    _mass[row * _gridColumns + targetColumn] >= _capacity[row * _gridColumns + targetColumn] * 0.9f)) continue;
                var targetRow = row + 1;
                var targetIndex = targetRow < _gridRows && targetColumn >= 0 && targetColumn < _gridColumns
                    ? targetRow * _gridColumns + targetColumn : -1;
                var end = targetIndex >= 0 ? Position(targetIndex) : new Vector2(start.X + dx * _cellSize, _height + _cellSize);
                var contact = landing(start, end, remaining);
                remaining = Math.Clamp(contact.Remaining, 0, remaining);
                if (contact.Blocked || remaining <= Epsilon) continue;
                if (targetIndex < 0 || _solid[targetIndex]) continue;
                var room = MathF.Max(0, _capacity[targetIndex] - _mass[targetIndex] - _incoming[targetIndex]);
                var moved = MathF.Min(remaining, room);
                if (moved <= Epsilon) continue;
                var needsSource = moved < remaining - Epsilon;
                var newTarget = _output[targetIndex] <= Epsilon;
                var unprocessed = _active.Count - offset - 1;
                if (newTarget && _nextActive.Count + unprocessed + (needsSource ? 2 : 1) > MaximumActive) continue;
                WriteOutput(targetIndex, moved);
                _incoming[targetIndex] += moved;
                remaining -= moved;
            }
            if (remaining > Epsilon) WriteOutput(index, remaining);
        }
        foreach (var index in _active) { _mass[index] = 0; _listed[index] = false; }
        foreach (var index in _nextActive) _incoming[index] = 0;
        (_mass, _output) = (_output, _mass);
        (_active, _nextActive) = (_nextActive, _active);
        foreach (var index in _active) _listed[index] = true;
        _tick++;
    }

    private void WriteOutput(int index, float amount)
    {
        if (!_listedOutput(index)) _nextActive.Add(index);
        _output[index] += amount;
    }

    private bool _listedOutput(int index) => _output[index] > Epsilon;

    private float Place(float amount, Vector2 point, Vector2 direction, (Vector2 Center, float Radius)? circle)
    {
        if (amount <= Epsilon) return 0;
        var origin = Index(point);
        if (origin < 0 || _solid[origin]) return amount;
        _visitGeneration++;
        if (_visitGeneration == 0) { Array.Clear(_visited); _visitGeneration = 1; }
        var head = 0; var tail = 0;
        _queue[tail++] = origin;
        _visited[origin] = _visitGeneration;
        var remaining = amount;
        while (head < tail && head < MaximumSearch && _placementVisits-- > 0)
        {
            var index = _queue[head++];
            var p = Position(index);
            var outside = circle is null || Vector2.DistanceSquared(p, circle.Value.Center) >=
                MathF.Pow(circle.Value.Radius + _cellSize * 0.55f, 2);
            if (outside)
            {
                var available = MathF.Max(0, _capacity[index] - _mass[index]);
                var accepted = MathF.Min(remaining, available);
                if (accepted > Epsilon)
                {
                    if (!_listed[index] && _active.Count >= MaximumActive) return remaining;
                    if (!_listed[index]) { _listed[index] = true; _active.Add(index); }
                    _mass[index] += accepted;
                    remaining -= accepted;
                    if (remaining <= Epsilon) return 0;
                }
            }
            var column = index % _gridColumns; var row = index / _gridColumns;
            var horizontal = MathF.Abs(direction.X) >= MathF.Abs(direction.Y);
            for (var neighbor = 0; neighbor < 4; neighbor++)
            {
                var dx = 0; var dy = 0;
                if (horizontal)
                {
                    var side = direction.X >= 0 ? 1 : -1;
                    if (neighbor == 0) dx = side;
                    else if (neighbor == 1) dy = -1;
                    else if (neighbor == 2) dy = 1;
                    else dx = -side;
                }
                else
                {
                    var side = direction.Y >= 0 ? 1 : -1;
                    if (neighbor == 0) dy = side;
                    else if (neighbor == 1) dx = 1;
                    else if (neighbor == 2) dx = -1;
                    else dy = -side;
                }
                var x = column + dx; var y = row + dy;
                if (x < 0 || x >= _gridColumns || y < 0 || y >= _gridRows) continue;
                var next = y * _gridColumns + x;
                if (_solid[next] || _visited[next] == _visitGeneration || tail >= _queue.Length) continue;
                _visited[next] = _visitGeneration; _queue[tail++] = next;
            }
        }
        return remaining;
    }

    private void Displace(Vector2 direction, (Vector2 Center, float Radius)? circle)
    {
        if (_affected.Count == 0) return;
        for (var i = 0; i < _affected.Count; i++) _mass[_affected[i]] = MathF.Max(0, _mass[_affected[i]] - _affectedMass[i]);
        Compact();
        for (var i = 0; i < _affected.Count; i++)
        {
            var rest = Place(_affectedMass[i], _targets[i], direction, circle);
            if (rest > Epsilon) Retain(rest, _targets[i]);
        }
    }

    private void Retain(float amount, Vector2 point)
    {
        if (amount <= Epsilon || !float.IsFinite(amount)) return;
        var total = _pendingMass + amount;
        _pendingPosition = _pendingMass <= Epsilon ? point : Vector2.Lerp(_pendingPosition, point, amount / total);
        _pendingMass = total;
    }

    private void Compact()
    {
        for (var i = _active.Count - 1; i >= 0; i--)
        {
            var index = _active[i];
            if (_mass[index] > Epsilon) continue;
            _mass[index] = 0; _listed[index] = false; _active.RemoveAt(i);
        }
    }

    private void BuildRenderView()
    {
        if (_active.Count == 0) { _renderCells.Clear(); _renderView = _renderCells; return; }
        var stride = 1;
        var renderColumns = _gridColumns;
        var renderRows = _gridRows;
        while ((long)renderColumns * renderRows > 4096)
        {
            stride++;
            renderColumns = (_gridColumns + stride - 1) / stride;
            renderRows = (_gridRows + stride - 1) / stride;
        }
        _renderPitch = stride * _cellSize;
        var count = Math.Min(4096, renderColumns * renderRows);
        Array.Clear(_renderMass, 0, count); Array.Clear(_renderCapacity, 0, count);
        for (var row = 0; row < renderRows; row++)
        for (var col = 0; col < renderColumns; col++)
        {
            var index = row * renderColumns + col;
            var x = col * stride * _cellSize;
            var y = row * stride * _cellSize;
            _renderCapacity[index] = MathF.Min(_width, x + stride * _cellSize) - x;
            _renderCapacity[index] *= MathF.Min(_height, y + stride * _cellSize) - y;
        }
        foreach (var index in _active)
        {
            var col = index % _gridColumns; var row = index / _gridColumns;
            var render = (row / stride) * renderColumns + col / stride;
            _renderMass[render] += _mass[index];
        }
        _renderCells.Clear();
        for (var row = 0; row < renderRows; row++)
        for (var col = 0; col < renderColumns; col++)
        {
            var index = row * renderColumns + col;
            var fill = _renderCapacity[index] > Epsilon ? _renderMass[index] / _renderCapacity[index] : 0;
            if (fill <= 0.002f) continue;
            var x = col * stride * _cellSize;
            var y = row * stride * _cellSize;
            _renderCells.Add(new SnowCell(
                new Vector2((x + MathF.Min(_width, x + stride * _cellSize)) * 0.5f,
                    (y + MathF.Min(_height, y + stride * _cellSize)) * 0.5f),
                new Vector2(MathF.Min(_width - x, stride * _cellSize), MathF.Min(_height - y, stride * _cellSize)),
                Math.Clamp(fill, 0, 1)));
        }
        _renderView = _renderCells;
    }

    private Vector2 Position(int index)
    {
        var x = (index % _gridColumns) * _cellSize;
        var y = (index / _gridColumns) * _cellSize;
        return new Vector2((x + MathF.Min(_width, x + _cellSize)) * 0.5f,
            (y + MathF.Min(_height, y + _cellSize)) * 0.5f);
    }

    private int Index(Vector2 point)
    {
        if (point.X < 0 || point.Y < 0 || point.X >= _width || point.Y >= _height) return -1;
        var column = Math.Min(_gridColumns - 1, (int)(point.X / _cellSize));
        var row = Math.Min(_gridRows - 1, (int)(point.Y / _cellSize));
        return row * _gridColumns + column;
    }

    private Vector2 ClampPoint(Vector2 point)
    {
        var halfX = MathF.Min(_cellSize * 0.5f, _width * 0.5f);
        var halfY = MathF.Min(_cellSize * 0.5f, _height * 0.5f);
        return new Vector2(Math.Clamp(point.X, halfX, _width - halfX), Math.Clamp(point.Y, halfY, _height - halfY));
    }

    private Vector2 LastFreePoint(Vector2 start, Vector2 desired)
    {
        var end = ClampPoint(desired);
        var delta = end - start;
        var length = delta.Length();
        var required = Math.Clamp((int)MathF.Ceiling(length / MathF.Max(1, _cellSize * 0.45f)), 1, 512);
        var previous = start;
        for (var i = 1; i <= required; i++)
        {
            if (_placementVisits-- <= 0) return previous;
            var candidate = start + delta * (i / (float)required);
            var index = Index(candidate);
            if (index < 0 || _solid[index]) return previous;
            previous = candidate;
        }
        return previous;
    }

    private bool SweptContains(Body oldBody, Body newBody, Vector2 point)
    {
        var delta = newBody.Position - oldBody.Position;
        var length = delta.Length();
        var steps = Math.Clamp((int)MathF.Ceiling(length / MathF.Max(1, _cellSize)), 1, 64);
        for (var step = 1; step <= steps; step++)
        {
            var position = oldBody.Position + delta * (step / (float)steps);
            var probe = oldBody with { Position = position, Size = Vector2.Lerp(oldBody.Size, newBody.Size, step / (float)steps) };
            if (probe.Contains(point)) return true;
        }
        return false;
    }

    private static Vector2 ClosestPoint(Vector2 point, Vector2 start, Vector2 end)
    {
        var delta = end - start;
        var lengthSquared = delta.LengthSquared();
        if (lengthSquared < 0.0001f) return start;
        return start + delta * Math.Clamp(Vector2.Dot(point - start, delta) / lengthSquared, 0, 1);
    }

    private static bool IsFinite(Vector2 value) => float.IsFinite(value.X) && float.IsFinite(value.Y);
}
