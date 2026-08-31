# Reward Pot

Reward Pot is a second loot mode for a profile. Instead of showing loot points, the raid window shows **Attendance** for each profile member and the current gold in a shared Reward Pot.

Only the profile owner can switch a profile between Point Based and Reward Pot. Switching modes hides the unused counter without wiping it. Loot points earned in Point Based remain stored while Reward Pot is active, and Attendance remains stored while Point Based is active.

## Attendance

The Loot Helper window title shows **Attendance**. Each profile member's row shows their Attendance total.

Profile admins can raise or lower Attendance one point at a time. Decreasing Attendance at zero does nothing. Attendance never goes below zero.

**Raid Check** awards `1` Attendance to each prepared profile member who is in the raid. **Pre-Raid Check** never changes Attendance.

## The pot

The current pot is the starting amount plus every logged add and subtract. It never goes below zero.

The raid window displays the current pot above the roster. It does not include editors. Profile admins add or subtract gold, and set the starting amount, under **Loot Helper → Profile**.

Gold amounts use WoW's gold, silver, and copper coins.

## Raid Check deductions

When **Raid Check** finds any evaluated profile member Unprepared, it subtracts from the pot once for that click. Inspection Failed does not count as Unprepared and does not deduct.

The deduction can be:

- a flat gold amount; or
- a percent of the current pot at the moment you run the check.

A percent that does not land on a whole copper amount is rounded down. The log stores the gold amount that was actually subtracted, not a live percent. Later pot changes do not rewrite that earlier deduction.

Example: a 10% deduction from a 500,000 gold pot records a 50,000 gold subtraction. Adding 1,000 gold afterward leaves 451,000 gold, not 501,000 gold.

If the configured amount is larger than the current pot, only the remaining gold is removed. A deduction of zero is skipped.

Never-inspectable players count as Unprepared. Inspection Failed (attempted inspect, incomplete or timed out) does not award Attendance and does not trigger the pot deduction.

Running Raid Check more than once can award Attendance and deduct from the pot again. Use Loot Logs if you need to correct an extra run.

## Settings

Open **Loot Helper → Profile** while Reward Pot is active to:

- see the current pot;
- set the starting pot;
- choose a flat or percent Raid Check deduction;
- add or subtract gold.

**Points Per Raid Check** is hidden in this mode because Raid Check awards Attendance instead.

## Related pages

- [Point Based](point-based.md)
- [Loot Helper](loot-helper.md)
- [Raid Check](raid-check.md)
- [Loot Logs](loot-logs.md)
