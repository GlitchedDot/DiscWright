// Capacity.cs — mirror of Capacity.swift / capacity.js: the
// ISO's exact sector total (from the writer's own planner)
// plus the burn's session overhead must fit the blank, or the
// build is refused.
using System.Collections.Generic;

namespace DiscWright.Core;

/// <summary>capacity.js's CapacityError (an Error subclass).</summary>
public class CapacityException : DiscCoreException
{
    public CapacityException(string message) : base(message) { }
}

public static class Capacity
{
    /// <summary>capacity.js re-exports iso.js's SECTOR.</summary>
    public const int Sector = Iso.IsoSector;
    public const int SessionOverheadSectors = 150 + 2 + 11400 + 157; // 11,709

    public static readonly IReadOnlyDictionary<int, string> Blanks =
        new Dictionary<int, string>
        {
            [360000] = "12 cm 80 min",
            [333000] = "12 cm 74 min",
            [108000] = "8 cm pocket 24 min",
            [94500] = "8 cm pocket 21 min",
            [405000] = "12 cm 90 min (overburn)",
            [445500] = "12 cm 99 min (overburn)",
        };

    /// <summary>CheckCapacity(fileSizes, capacitySectors) -> estimated sectors.</summary>
    public static int CheckCapacity(IReadOnlyDictionary<string, int> fileSizes,
                                    int capacitySectors)
    {
        int est = Iso.IsoSectorCount(fileSizes);
        if (est + SessionOverheadSectors > capacitySectors)
        {
            string name = Blanks.TryGetValue(capacitySectors, out string? b)
                ? b
                : "custom";
            throw new CapacityException(
                $"ISO needs {est} sectors + {SessionOverheadSectors} session " +
                $"overhead = {est + SessionOverheadSectors}, exceeds blank " +
                $"capacity {capacitySectors} sectors ({name})");
        }
        return est;
    }
}
