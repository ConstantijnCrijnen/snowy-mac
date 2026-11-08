using System.Numerics;
using Snowy.Core;

var cases = new (string Name, Action Run)[]
{
    ("snowfall collects on the upper surface without passing through windows", SnowfallStopsAtFirstSurface),
    ("a moving window hands overlapping snow to the window beneath it", MovingWindowTransfersOverlap),
    ("a newly opened window removes only the snow it covers", NewWindowRemovesCoveredMass),
    ("wind shadow blocks snowfall but shovel placement remains available", WindShadowDoesNotBlockSweeping),
    ("decorations accept falling snow as physical surfaces", DecorationsCatchSnow),
    ("snow from a closed support falls onto the lower exposed window", ClosedSupportSnowFallsDown),
    ("moving windows push covered snow toward either leading side", MovingWindowPushesBothWays),
    ("loose snow rebounds from a window wall on its entry side", ParcelReboundsFromRightWall),
    ("the snow cap continues falling after a surface reaches its limit", SnowfallContinuesAtCapacity),
    ("large synthetic decoration IDs retain a varied cap silhouette", LargeDecorationIdsKeepLobes),
    ("loose snow remains represented while in flight", PushedSnowKeepsVisibleMass),
    ("oversized rounded body corners remain safe and consistent", OversizedBodyCornersAreClamped),
};

foreach (var test in cases)
{
    test.Run();
    Console.WriteLine($"PASS {test.Name}");
}

static void SnowfallStopsAtFirstSurface()
{
    var snow = new SnowSimulation(600, 500);
    snow.SetBodies(new[]
    {
        new Body(1, Vector2.Zero, new Vector2(600, 150)),
        new Body(2, new Vector2(0, 250), new Vector2(600, 220)),
    });
    Advance(snow, 900);
    var upper = Profile(snow, 1);
    var lower = Profile(snow, 2);
    Check(upper.Heights.Max() > 1, "The exposed top window should collect snow.");
    Check(lower.Heights.Max() < 0.001f, "The covered lower window must stay clear.");
}

static void MovingWindowTransfersOverlap()
{
    var snow = new SnowSimulation(600, 500);
    var upper = new Body(1, new Vector2(0, 200), new Vector2(600, 190));
    var lower = new Body(2, new Vector2(0, 300), new Vector2(600, 190));
    snow.SetBodies(new[] { upper, lower });
    Advance(snow, 900);
    Check(Profile(snow, 1).Heights.Max() > 1, "The upper window needs a pile before moving.");
    snow.SetBodies(new[] { upper with { Position = new Vector2(0, 310) }, lower });
    Check(Profile(snow, 2).Heights.Max() > 0.1f, "Snow crossing the lower window's top should transfer onto it.");
}

static void NewWindowRemovesCoveredMass()
{
    var snow = new SnowSimulation(600, 500);
    var original = new Body(1, new Vector2(0, 250), new Vector2(600, 200));
    snow.SetBodies(new[] { original });
    Advance(snow, 900);
    var before = Profile(snow, 1);
    var coveredBefore = At(before, 140);
    var clearBefore = At(before, 420);
    Check(coveredBefore > 1 && clearBefore > 1, "The source cap should have snow on both sides.");
    snow.SetBodies(new[]
    {
        original,
        new Body(2, new Vector2(80, 220), new Vector2(140, 260)),
    });
    var after = Profile(snow, 1);
    Check(At(after, 140) < 0.001f, "Snow covered by the new window should be removed.");
    Check(MathF.Abs(At(after, 420) - clearBefore) < 0.05f, "Snow outside the new window must remain.");
}

static void WindShadowDoesNotBlockSweeping()
{
    var snow = new SnowSimulation(700, 500);
    snow.SetBodies(new[]
    {
        new Body(1, new Vector2(80, 260), new Vector2(600, 180)),
        new Body(2, new Vector2(320, 220), new Vector2(110, 30), BodyKind.Window, 0),
    });
    Advance(snow, 900);
    var profile = Profile(snow, 1);
    var before = At(profile, 460);
    Check(before > 1, "The downwind sample must initially have a snow pile.");
    var worldX = profile.X + 460;
    snow.Step(0.05f, Snowfall.Flurry, new Vector2(1, 0), null, SnowTool.Glove, false);
    Check(MathF.Abs(At(Profile(snow, 1), 460) - before) < 0.05f,
        "Changing wind must not eject existing snow from its shadow.");
    snow.Step(0.05f, Snowfall.Flurry, new Vector2(1, 0), new Vector2(worldX, profile.Y - before * 0.5f), SnowTool.Shovel, false);
    Check(At(Profile(snow, 1), 460) < before, "The shovel must still remove snow from a wind shadow.");
    Check(snow.TotalLooseMass > 0, "Swept snow must remain in the moving material field.");
    Check(snow.LooseCells.Count > 0 && snow.LooseCells.Count <= 4096 && snow.LooseCellPitch > 0,
        "Loose snow must remain visible in a bounded connected render grid.");
}

static void DecorationsCatchSnow()
{
    var snow = new SnowSimulation(600, 500);
    snow.SetBodies(new[]
    {
        new Body(91, new Vector2(120, 320), new Vector2(360, 80), BodyKind.Decoration, 0),
    });
    Advance(snow, 900);
    Check(Profile(snow, 91).Heights.Max() > 1, "A decoration collider should accumulate snowfall.");
}

static void ClosedSupportSnowFallsDown()
{
    var snow = new SnowSimulation(600, 500);
    var upper = new Body(1, new Vector2(0, 160), new Vector2(600, 120));
    var lower = new Body(2, new Vector2(0, 310), new Vector2(600, 150));
    snow.SetBodies(new[] { upper, lower });
    Advance(snow, 900);
    var carriedMass = Profile(snow, 1).Heights.Sum() * Profile(snow, 1).Spacing;
    Check(carriedMass > 100, "The upper support should have substantial settled snow.");
    snow.SetBodies(new[] { lower });
    Check(snow.TotalLooseMass > carriedMass * 0.99f, "Closing the support should release its snow into gravity.");
    Advance(snow, 160);
    Check(Profile(snow, 2).Heights.Max() > 1, "Released snow should settle on the newly exposed lower window.");
}

static void MovingWindowPushesBothWays()
{
    AssertLeadingPush(700, 100, expectRight: false);
    AssertLeadingPush(-180, 340, expectRight: true);
}

static void AssertLeadingPush(float startingX, float targetX, bool expectRight)
{
    var snow = new SnowSimulation(600, 500);
    var support = new Body(1, new Vector2(0, 300), new Vector2(600, 180));
    snow.SetBodies(new[] { support });
    Advance(snow, 900);
    Check(Profile(snow, 1).Heights.Max() > 1, "The stationary support should hold snow before the window arrives.");

    var oldWindow = new Body(2, new Vector2(startingX, 240), new Vector2(120, 120));
    var movedWindow = oldWindow with { Position = new Vector2(targetX, 240) };
    snow.SetBodies(new[] { support, oldWindow });
    snow.SetBodies(new[] { support, movedWindow });
    Check(snow.TotalLooseMass > 0, "The moving window should dislodge snow it sweeps through.");
    if (expectRight)
        Check(snow.LooseCells.Any(cell => cell.Center.X > targetX + movedWindow.Size.X),
            "Rightward motion should push snow beyond the right boundary.");
    else
        Check(snow.LooseCells.Any(cell => cell.Center.X < targetX),
            "Leftward motion should push snow beyond the left boundary.");
}

static void ParcelReboundsFromRightWall()
{
    var snow = new SnowSimulation(600, 500);
    var support = new Body(1, new Vector2(0, 300), new Vector2(600, 180));
    var wall = new Body(2, new Vector2(240, 260), new Vector2(105, 45), BodyKind.Window, 0);
    snow.SetBodies(new[] { support, wall });
    Advance(snow, 900);

    var oldMover = new Body(3, new Vector2(800, 240), new Vector2(120, 120));
    var newMover = oldMover with { Position = new Vector2(350, 240) };
    snow.SetBodies(new[] { support, wall, oldMover });
    snow.SetBodies(new[] { support, wall, newMover });
    Check(snow.LooseCells.Count > 0 && snow.LooseCells.Min(cell => cell.Center.X) < newMover.Left,
        "The leftward-moving window should eject material toward the nearby wall.");

    Advance(snow, 20);
    Check(snow.LooseCells.Any(cell => cell.Center.X > wall.Right),
        "Material arriving from the wall's right side should rebound to that side.");
}

static void SnowfallContinuesAtCapacity()
{
    var snow = new SnowSimulation(600, 500);
    snow.SetBodies(new[] { new Body(1, new Vector2(0, 300), new Vector2(600, 180)) });
    Advance(snow, 2200);
    Check(Profile(snow, 1).Heights.Max() <= 18.01f, "Snow depth remains capped.");
    var flakeCount = snow.Flakes.Count;
    Advance(snow, 40);
    Check(snow.Flakes.Count == flakeCount && flakeCount > 0, "Snowfall particles continue at the cap.");
}

static void LargeDecorationIdsKeepLobes()
{
    var snow = new SnowSimulation(700, 500);
    snow.SetBodies(new[] { new Body(8_000_000_000_000_123, new Vector2(40, 280), new Vector2(620, 100), BodyKind.Decoration, 0) });
    Advance(snow, 900);
    var heights = Profile(snow, 8_000_000_000_000_123).Heights;
    Check(heights.Max() - heights.Min() > 0.25f,
        "A large decoration ID must not erase the spatial variation in the snow cap.");
}

static void PushedSnowKeepsVisibleMass()
{
    var snow = new SnowSimulation(600, 500);
    var support = new Body(1, new Vector2(0, 300), new Vector2(600, 180));
    snow.SetBodies(new[] { support });
    Advance(snow, 900);
    var before = snow.TotalSettledMass;
    snow.Step(0.05f, Snowfall.Flurry, Vector2.Zero, new Vector2(300, 280), SnowTool.Shovel, false);
    Check(snow.TotalLooseMass > 0 && snow.LooseCells.Count > 0,
        "Swept mass must have a visible cellular representation while it moves.");
    Check(snow.TotalSettledMass < before,
        "Sweeping should take mass off the profile and move it into the field.");
}

static void OversizedBodyCornersAreClamped()
{
    var body = new Body(99, Vector2.Zero, new Vector2(8, 8), BodyKind.Decoration, 100);
    Check(body.Contains(new Vector2(4, 4)), "A tiny body should contain its center after radius clamping.");
    Check(!body.Contains(new Vector2(8, 8)), "The clamped rounded hit box should not include the distant corner.");
}

static void Advance(SnowSimulation simulation, int frames)
{
    for (var i = 0; i < frames; i++) simulation.Step(0.05f, Snowfall.Flurry, Vector2.Zero, null, SnowTool.Glove, false);
}

static SnowProfile Profile(SnowSimulation simulation, long id) => simulation.Profiles.Single(profile => profile.Id == id);

static float At(SnowProfile profile, float x)
{
    var coordinate = x / profile.Spacing;
    var index = Math.Clamp((int)MathF.Floor(coordinate), 0, profile.Heights.Length - 2);
    var fraction = coordinate - index;
    return profile.Heights[index] + (profile.Heights[index + 1] - profile.Heights[index]) * fraction;
}

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
