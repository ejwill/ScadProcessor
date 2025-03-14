/*Created by Andy (BlackjackDuck)

This code is licensed Creative Commons 4.0 Attribution Non-Commercial Sharable with Attribution
References to Multipoint are for the Multiboard ecosystem by Jonathan at Keep Making. The Multipoint mount system is licensed under https://www.multiboard.io/license.

Credit to
@David D on Printables for Multiconnect
Jonathan at Keep Making for Multiboard
@fawix on GitHub for her contributions on parameter descriptors
@SnazzyGreenWarrior on GitHub for their contributions on the Multipoint-compatible mount

Change Log:
- 2024-08-10
- Initial release
- 2024-12-08
- Multiconnect on-ramps now in-between grids for easier mounting
- Rounded edges to Item Holder
- Thanks @user_2270779674 on MakerWorld!
- Multiconnect On-Ramps at 1/2 grid intervals for more contact points
- Rounding added to edges
- 2025-01-02
- Multipoint mounting
- Thanks @SnazzyGreenWarrior!
- 2025-01-16
- Added GOEWS cleats option (@andrew_3d)

Notes:
- Slot test fit - For a slot test fit, set the following parameters
- internalDepth = 0
- internalHeight = 25
- internalWidth = 0
- wallThickness = 0
*/

include<BOSL2/std.scad>
include<BOSL2/walls.scad>

// === Begin content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/mounting_backers.scad ===
/*[GOEWS Customization]*/

GOEWS_Cleat_position = "normal"; // [normal, top, bottom, custom]
GOEWS_Cleat_custom_height_from_top_of_back = 11.24;
/*
Created by Andy (BlackjackDuck)

This code is licensed Creative Commons 4.0 Attribution Non-Commercial Sharable with Attribution
References to Multipoint are for the Multiboard ecosystem by Jonathan at Keep Making. The Multipoint mount system is licensed under https://www.multiboard.io/license.

Credit to
@David D on Printables for Multiconnect
Jonathan at Keep Making for Multiboard
@SnazzyGreenWarrior on GitHub for their contributions on the Multipoint-compatible mount
MrExo3D on Printables for the GOEWS system

Using this module:
This module imports the various mounting systems created within the QuackWorks repo and generates a "backer plate" with that standard. The backer plate is a flat plate intended to be attached to the back of various items to be mounted.
Parameters below should be passed to the main module to appear in the customizer.
Primary inputs are width and height.
distanceBetweenSlots is indicative to the grid size and drives the distance between slots or other mounting points.
*/


// === Begin content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/goews.scad ===


//Create GOEWS cleats
// main profile
// angled slice off bottom
// cutout
module GOEWSCleatTool(totalHeight) {
difference() {
rotate(a = [180,0,0])
linear_extrude(height = 13.15)
let (cleatProfile = [[0,0],[15.1,0],[17.6,2.5],[15.1,5],[0,5]])
union(){
polygon(points = cleatProfile);
mirror([1,0,0])
polygon(points = cleatProfile);
};
translate([-17.6, -8, -26.3])
rotate([45, 0, 0])
translate([0, 5, 0])
cube([35.2, 10, 15]);
translate([0, -0.005, 2.964])
rotate([90, 0, 0])
cylinder(h = 6, r = 9.5, $fn = 256);
}
}
// === End content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/goews.scad ===
// === Begin content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/multiconnect.scad ===
//Create Slot Tool
//In slotTool, added a new variable distanceOffset which is set by the option:
//slot minus optional dimple with optional on-ramp
//round top
//long slot
//on-ramp
//then modify the translate within the on-ramp code to include the offset
//dimple
module multiConnectSlotTool(totalHeight, onRampEveryXSlots = 1) {
distanceOffset = onRampHalfOffset ? distanceBetweenSlots / 2 : 0;
scale(v = slotTolerance)
let (slotProfile = [[0,0],[10.15,0],[10.15,1.2121],[7.65,3.712],[7.65,5],[0,5]])
difference() {
union() {
rotate(a = [90,0,0,])
rotate_extrude($fn=50)
polygon(points = slotProfile);
translate(v = [0,0,0])
rotate(a = [180,0,0])
linear_extrude(height = totalHeight+1)
union(){
polygon(points = slotProfile);
mirror([1,0,0])
polygon(points = slotProfile);
}
if(onRampEnabled)
for(y = [1:onRampEveryXSlots:totalHeight/distanceBetweenSlots])
translate(v = [0,-5,(-y*distanceBetweenSlots)+distanceOffset])
rotate(a = [-90,0,0])
cylinder(h = 5, r1 = 12, r2 = 10.15);
}
if (slotQuickRelease == false)
scale(v = dimpleScale)
rotate(a = [90,0,0,])
rotate_extrude($fn=50)
polygon(points = [[0,0],[0,1.5],[1.5,0]]);
}
}
// === End content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/multiconnect.scad ===
// === Begin content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/multipoint.scad ===
//octagonal top. difference on union because we need to support the dimples cut in.
//union of top and rail.
//long slot
//dimples on each catch point
//on-ramp
// create the main entry hexagons
// make the required "pop-in" locking channel dimples.
module multiPointSlotTool(totalHeight, onRampEveryXSlots = 1) {
slotBaseRadius = 17.0 / 2.0;  // wider width of the inner part of the channel
slotSkinRadius = 13.75 / 2.0;  // narrower part of the channel near the skin of the model
slotBaseCatchDepth = .2;  // innermost before the chamfer, base to chamfer height
slotBaseToSkinChamferDepth = 2.2;  // middle part of the chamfer
slotSkinDepth = .1;  // top or skinmost part of the channel
distanceOffset = onRampHalfOffset ? distanceBetweenSlots / 2 : 0;
octogonScale = 1/sin(67.5);  // math convenience function to convert an octogon hypotenuse to the short length
let (slotProfile = [
[0,0],
[slotBaseRadius,0],
[slotBaseRadius, slotBaseCatchDepth],
[slotSkinRadius, slotBaseCatchDepth + slotBaseToSkinChamferDepth],
[slotSkinRadius, slotBaseCatchDepth + slotBaseToSkinChamferDepth + slotSkinDepth],
[0, slotBaseCatchDepth + slotBaseToSkinChamferDepth + slotSkinDepth]
])
union() {
difference(){
union(){
scale([octogonScale,1,octogonScale])
rotate(a = [90,67.5,0,])
rotate_extrude($fn=8)
polygon(points = slotProfile);
translate(v = [0,0,0])
rotate(a = [180,0,0])
linear_extrude(height = totalHeight+1)
union(){
polygon(points = slotProfile);
mirror([1,0,0])
polygon(points = slotProfile);
}
}
if (!slotQuickRelease){
for(z = [1:onRampEveryXSlots:totalHeight/distanceBetweenSlots ])
{
echo("building on z", z);
yMultipointSlotDimples(z, slotBaseRadius, distanceBetweenSlots, distanceOffset);
}
}
}
if(onRampEnabled)
union(){
for(y = [1:On_Ramp_Every_X_Slots:totalHeight/distanceBetweenSlots])
{
translate(v = [0,-5,(-y*distanceBetweenSlots)+distanceOffset])
scale([octogonScale,1,octogonScale])
rotate(a = [-90,67.5,0])
cylinder(h=5, r=slotBaseRadius, $fn=8);

xSlotDimples(y, slotBaseRadius, distanceBetweenSlots, distanceOffset);
mirror([1,0,0])
xSlotDimples(y, slotBaseRadius, distanceBetweenSlots, distanceOffset);
}
}
}
}

//Multipoint dimples are truncated (on top and side) pyramids
//this function makes one pair of them
module xSlotDimples(y, slotBaseRadius, distanceBetweenSlots, distanceOffset){
dimple_pitch = 4.5 / 2; //distance between locking dimples
difference(){
translate(v = [slotBaseRadius-0.01,0,(-y*distanceBetweenSlots)+distanceOffset+dimple_pitch])
rotate(a = [90,45,90])
rotate_extrude($fn=4)
polygon(points = [[0,0],[0,1.5],[1.7,0]]);
translate(v = [slotBaseRadius+.75, -2, (-y*distanceBetweenSlots)+distanceOffset-1])
cube(4);
translate(v = [slotBaseRadius-2, 0.01, (-y*distanceBetweenSlots)+distanceOffset-1])
cube(7);
}
difference(){
translate(v = [slotBaseRadius-0.01,0,(-y*distanceBetweenSlots)+distanceOffset-dimple_pitch])
rotate(a = [90,45,90])
rotate_extrude($fn=4)
polygon(points = [[0,0],[0,1.5],[1.7,0]]);
translate(v = [slotBaseRadius+.75, -2.01, (-y*distanceBetweenSlots)+distanceOffset-3])
cube(4);
translate(v = [slotBaseRadius-2, 0.01, (-y*distanceBetweenSlots)+distanceOffset-5])
cube(10);
}
}
//This creates the multipoint point out dimples within the channel.
module yMultipointSlotDimples(z, slotBaseRadius, distanceBetweenSlots, distanceOffset){
octogonScale = 1/sin(67.5);
difference(){
translate(v = [0,0.01,((-z+.5)*distanceBetweenSlots)+distanceOffset])
scale([octogonScale,1,octogonScale])
rotate(a = [-90,67.5,0])
rotate_extrude($fn=8)
polygon(points = [[0,0],[0,-1.5],[5,0]]);
translate(v = [0,0,((-z+.5)*distanceBetweenSlots)+distanceOffset])
cube([10,3,3], center=true);
translate(v = [0,0,((-z+.5)*distanceBetweenSlots)+distanceOffset])
cube([3,3,10], center=true);
}
}
// === End content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/multipoint.scad ===

// === End content from /Users/erwinwill/Documents/Programming/ScadProcessor/lib/mounting_backers.scad ===

