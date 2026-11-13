import Cocoa
import SceneKit
import ServiceManagement
import AVFoundation
import Metal

let prefs = UserDefaults.standard
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(calibratedRed:r,green:g,blue:b,alpha:a) }
func fill(_ rect: NSRect, _ c: NSColor, radius: CGFloat = 0) { c.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill() }
func oval(_ rect: NSRect, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn:rect).fill() }
func line(_ points: [NSPoint], _ c: NSColor, _ width: CGFloat) { guard let p = points.first else{return}; let path=NSBezierPath(); path.move(to:p); for pt in points.dropFirst(){path.line(to:pt)};path.lineWidth=width;path.lineCapStyle = .round;c.setStroke();path.stroke() }
func label(_ text:String,_ rect:NSRect,_ size:CGFloat,_ c:NSColor,_ weight:NSFont.Weight = .regular) { (text as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:c]) }
struct Album { let key:String; let title:String; let artist:String; var art:NSImage; let listenedAt:Date = Date() }

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next()) / Double(UInt64.max)) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
}

func hashSeed(_ text: String) -> UInt64 {
    text.utf8.reduce(1469598103934665603) { (($0 ^ UInt64($1)) &* 1099511628211) }
}

struct VinylVariant {
    enum Style: CaseIterable { case black, translucent, splatter, marble, smoke, pinwheel, twotone }
    let style: Style
    let base: NSColor
    let accent: NSColor
    let accent2: NSColor
    let translucent: Bool
    var name:String {
        switch style {
        case .black:return "Classic black"
        case .translucent:return "Jewel tone"
        case .splatter:return "Color splash"
        case .marble:return "Mineral marble"
        case .twotone:return "Split pressing"
        case .smoke:return "Smoked vinyl"
        case .pinwheel:return "Pinwheel"
        }
    }
}

final class ArtworkTicket: @unchecked Sendable {
    private let lock=NSLock();private var cancelled=false
    var isCancelled:Bool{lock.lock();defer{lock.unlock()};return cancelled}
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
}

final class PreparedPressing:NSObject {
    let variant:VinylVariant, texture:CGImage, label:CGImage, cover:CGImage
    init(_ variant:VinylVariant,_ texture:CGImage,_ label:CGImage,_ cover:CGImage){
        self.variant=variant;self.texture=texture;self.label=label;self.cover=cover
    }
}

final class RoomView: SCNView {
    static let pressingCache:NSCache<NSString,PreparedPressing> = {let c=NSCache<NSString,PreparedPressing>();c.countLimit=24;c.totalCostLimit=96*1024*1024;return c}()
    static let textureQueue=DispatchQueue(label:"recordroom.textures",qos:.userInitiated)
    var preparingKey:String?,gpuReadyKey:String?
    var preparationTicket:ArtworkTicket?
    var readyPressing:(key:String,value:PreparedPressing)?
    var exchangeStarted:Date?, armStarted:Date?

    var mode=0
    var crateKeys:Set<String>=[]
    var sceneStyle:Int=0 {didSet{if oldValue != sceneStyle{applyStyle()}}}
    var album:NSImage? {didSet{
        if oldValue.map({ObjectIdentifier($0)}) != album.map({ObjectIdentifier($0)}){preparationTicket?.cancel();preparingKey=nil;gpuReadyKey=nil}
        updateCurrent()
    }}
    var stack:[Album]=[] {didSet{if oldValue.map(\.key) != stack.map(\.key){updateCrate()}}}
    var currentKey="" {didSet{if oldValue != currentKey{
        preparationTicket?.cancel();preparingKey=nil;gpuReadyKey=nil
        if mode==0 && !reducingMotion && window != nil && !lastArtworkKey.isEmpty && !exchanging{pendingCover=nil;beginRecordExchange()}
        updateCrate()
    }}}
    var angle:CGFloat=0 {didSet{record.eulerAngles.y = angle}}
    var styleApplied=false,styleTransitionUntil=Date.distantPast
    var reducingMotion=false
    var playbackActive=false
    var songFraction:CGFloat=0, playbackDuration:Double=1
    var playbackTrack="", armTransitioning=false
    var recordAngularVelocity:CGFloat=0
    var exchanging=false, exchangeWaiting=false
    var pendingCover:(key:String,art:NSImage)?
    var speakerCones:[SCNNode]=[], coneRestDepth:[CGFloat]=[]
    var lastArtworkIdentity:ObjectIdentifier?, lastArtworkKey=""
    let tonearmPivot=SCNNode(), tonearmLift=SCNNode()
    let powerLens=SCNMaterial()
    var onSelect:((String)->Void)?
    let world=SCNScene(), cameraNode=SCNNode(), record=SCNNode(), sleeve=SCNNode(), crateRecords=SCNNode(), keyLight=SCNNode(), ambient=SCNNode()
    let sleeveFace=SCNMaterial(), discLabel=SCNMaterial(), discSurface=SCNMaterial(), discEdge=SCNMaterial()

    override init(frame:NSRect,options:[String:Any]?=nil){super.init(frame:frame,options:options);build()}
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}

    func material(_ c:NSColor,metal:CGFloat=0,rough:CGFloat=0.6)->SCNMaterial{let m=SCNMaterial();m.diffuse.contents=c;m.lightingModel = .physicallyBased;m.metalness.contents=metal;m.roughness.contents=rough;return m}
    // Shared, baked material maps add physical detail without per-frame noise shaders.
    static let woodMap:NSImage = NSImage(size:NSSize(width:512,height:512),flipped:false){r in
        fill(r,color(0.24,0.125,0.065))
        for i in 0..<210{
            let y=CGFloat(i)*2.5
            let path=NSBezierPath();path.move(to:NSPoint(x:-5,y:y))
            path.curve(to:NSPoint(x:517,y:y+3*sin(CGFloat(i)*0.19)),controlPoint1:NSPoint(x:175,y:y+4*sin(CGFloat(i)*0.11)),controlPoint2:NSPoint(x:350,y:y-3*cos(CGFloat(i)*0.13)))
            color(0.07,0.035,0.015,i % 7==0 ? 0.16:0.065).setStroke();path.lineWidth=i % 7==0 ? 0.8:0.45;path.stroke()
        };return true
    }
    lazy var walnut:SCNMaterial = {
        let m=material(.white,rough:0.48);m.diffuse.contents=Self.woodMap
        m.diffuse.wrapS = .repeat;m.diffuse.wrapT = .repeat;m.diffuse.mipFilter = .linear;m.diffuse.maxAnisotropy=4
        return m
    }()
    func woodFinish(_ offset:CGFloat)->SCNMaterial{
        let m=walnut.copy() as! SCNMaterial;m.diffuse.contentsTransform=SCNMatrix4MakeTranslation(offset,0,0);return m
    }
    lazy var crateWood=woodFinish(0.31)
    lazy var speakerWood=woodFinish(0.67)
    lazy var paperEdge:SCNMaterial = {
        let m=material(.white,rough:0.95);m.name="sleeve-paper"
        m.diffuse.contents=NSImage(size:NSSize(width:256,height:64),flipped:false){r in
            fill(r,color(0.82,0.80,0.74));fill(NSRect(x:0,y:30,width:256,height:1),color(0.47,0.44,0.38,0.32))
            for i in 0..<100{let x=CGFloat((i*67)%256),y=CGFloat((i*37)%64);fill(NSRect(x:x,y:y,width:1.5,height:0.6),color(0.45,0.42,0.35,0.16))};return true
        };return m
    }()
    lazy var jacketBack:SCNMaterial = {
        let m=material(.white,rough:0.93);m.name="sleeve-back"
        m.diffuse.contents=NSImage(size:NSSize(width:512,height:512),flipped:false){r in
            fill(r,color(0.82,0.80,0.74))
            for x:CGFloat in [9,502]{fill(NSRect(x:x,y:7,width:1,height:498),color(0.42,0.39,0.32,0.20))}
            fill(NSRect(x:9,y:9,width:494,height:1),color(0.42,0.39,0.32,0.20));return true
        };return m
    }()
    func configureVinylFinish(){
        discSurface.roughness.contents=NSImage(size:NSSize(width:1024,height:1024),flipped:false){r in
            fill(r,NSColor(white:0.20,alpha:1))
            fill(r.insetBy(dx:28,dy:28),NSColor(white:0.20,alpha:1))
            NSColor(white:0.35,alpha:1).setFill();NSBezierPath(ovalIn:r.insetBy(dx:48,dy:48)).fill()
            NSColor(white:0.22,alpha:1).setFill();NSBezierPath(ovalIn:r.insetBy(dx:335,dy:335)).fill()
            for i in 0..<95{
                let inset=CGFloat(50+i*3);let path=NSBezierPath(ovalIn:r.insetBy(dx:inset,dy:inset));path.lineWidth=0.8
                NSColor(white:0.29,alpha:1).setStroke();path.stroke()
            };return true
        }
        discSurface.roughness.mipFilter = .linear;discSurface.roughness.maxAnisotropy=8
        sleeveFace.roughness.contents=NSImage(size:NSSize(width:128,height:128),flipped:false){r in
            fill(r,NSColor(white:0.90,alpha:1))
            for i in 0..<600{fill(NSRect(x:(i*37)%128,y:(i*71)%128,width:1,height:1),NSColor(white:i%2==0 ? 0.85:0.94,alpha:1))};return true
        }
        sleeveFace.roughness.wrapS = .repeat;sleeveFace.roughness.wrapT = .repeat;sleeveFace.roughness.mipFilter = .linear
    }

    @discardableResult func box(_ w:CGFloat,_ h:CGFloat,_ d:CGFloat,_ position:SCNVector3,_ mat:SCNMaterial,_ radius:CGFloat=0.015,parent:SCNNode?=nil)->SCNNode{
        let g=SCNBox(width:w,height:h,length:d,chamferRadius:radius);g.chamferSegmentCount=3;g.materials=[mat];let n=SCNNode(geometry:g);n.position=position;(parent ?? world.rootNode).addChildNode(n);return n
    }

    @discardableResult func cylinder(_ r:CGFloat,_ h:CGFloat,_ pos:SCNVector3,_ mat:SCNMaterial,parent:SCNNode?=nil)->SCNNode{
        let g=SCNCylinder(radius:r,height:h);g.radialSegmentCount=r>1 ? 192:(r>0.1 ? 48:24);g.materials=[mat];let n=SCNNode(geometry:g);n.position=pos;(parent ?? world.rootNode).addChildNode(n);return n
    }

    func rod(_ a:SCNVector3,_ b:SCNVector3,_ radius:CGFloat,_ mat:SCNMaterial,parent:SCNNode?=nil){
        let dx=b.x-a.x,dy=b.y-a.y,dz=b.z-a.z
        let n=cylinder(radius,CGFloat(sqrt(dx*dx+dy*dy+dz*dz)),SCNVector3((a.x+b.x)/2,(a.y+b.y)/2,(a.z+b.z)/2),mat,parent:parent)
        n.look(at:(parent ?? world.rootNode).convertPosition(b,to:nil),up:world.rootNode.worldUp,localFront:SCNVector3(0,1,0))
    }

    func inscription(_ text:String,width:CGFloat,height:CGFloat,position:SCNVector3,top:Bool=true){
        let ink=SCNMaterial();ink.lightingModel = .constant;ink.isDoubleSided=false
        ink.diffuse.contents=NSImage(size:NSSize(width:1024,height:160),flipped:false){rect in
            let style=NSMutableParagraphStyle();style.alignment = .center
            (text as NSString).draw(in:rect.insetBy(dx:12,dy:20),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:76,weight:.medium),.foregroundColor:color(0.12,0.14,0.14),.paragraphStyle:style]);return true
        }
        ink.diffuse.mipFilter = .linear
        let plane=SCNPlane(width:width,height:height);plane.materials=[ink]
        let node=SCNNode(geometry:plane);node.position=position
        if top{node.eulerAngles.x = -.pi/2};world.rootNode.addChildNode(node)
    }

    func buildTurntableDetails(metal:SCNMaterial,black:SCNMaterial){
        let satin=material(color(0.46,0.49,0.50),metal:0.8,rough:0.42)
        let rubber=material(color(0.035,0.038,0.039),rough:0.88)
        let cartridge=material(color(0.24,0.29,0.28),metal:0.12,rough:0.48)
        // Layered platter rim and damping mat, clear of the rotating disc.
        cylinder(1.325,0.025,SCNVector3(-0.79,0.601,0.06),rubber)
        cylinder(1.328,0.016,SCNVector3(-0.79,0.652,0.06),satin)
        cylinder(1.325,0.014,SCNVector3(-0.79,0.688,0.06),metal)
        cylinder(1.292,0.014,SCNVector3(-0.79,0.700,0.06),rubber)

        // The bearing ring belongs to the yaw pivot; the assembly lifts around it.
        let bearing=SCNTorus(ringRadius:0.10,pipeRadius:0.019)
        bearing.ringSegmentCount=48;bearing.pipeSegmentCount=12;bearing.materials=[satin]
        let ring=SCNNode(geometry:bearing);ring.eulerAngles.z = .pi/2;tonearmPivot.addChildNode(ring)
        rod(SCNVector3(-0.14,0,0),SCNVector3(0.14,0,0),0.026,metal,parent:tonearmPivot)
        rod(SCNVector3(0,0,0),SCNVector3(0.03,0,-0.36),0.029,metal,parent:tonearmLift)
        let weight=cylinder(0.104,0.19,SCNVector3(0.025,0,-0.28),satin,parent:tonearmLift)
        weight.eulerAngles.x = .pi/2
        let collar=cylinder(0.107,0.024,SCNVector3(0.02,0,-0.18),black,parent:tonearmLift)
        collar.eulerAngles.x = .pi/2
        // Headshell, cartridge and cantilever move as one rigid assembly.
        let head=SCNNode();head.position=SCNVector3(-0.84,-0.10,1.95);head.eulerAngles.y = -0.77
        tonearmLift.addChildNode(head)
        box(0.145,0.025,0.29,SCNVector3Zero,satin,0.012,parent:head)
        box(0.105,0.061,0.17,SCNVector3(0,-0.043,0.035),cartridge,0.010,parent:head)
        box(0.095,0.022,0.055,SCNVector3(0,-0.079,0.091),black,0.005,parent:head)
        rod(SCNVector3(0,-0.087,0.075),SCNVector3(0,-0.107,0.125),0.005,metal,parent:head)
        for z:CGFloat in [-0.07,0.05]{
            cylinder(0.014,0.008,SCNVector3(0,0.017,z),black,parent:head)
        }
        rod(SCNVector3(0.06,0,0.02),SCNVector3(0.16,0.055,0.05),0.012,satin,parent:head)
        // A restrained control cluster: recessed screws, dial index and tiny amber lens.
        for x:CGFloat in [-2.24,1.54]{for z:CGFloat in [-1.40,1.40]{
            cylinder(0.025,0.004,SCNVector3(x,0.585,z),satin)
            box(0.027,0.001,0.004,SCNVector3(x,0.588,z),black,0)
        }}
        box(0.008,0.004,0.047,SCNVector3(-2.02,0.660,1.16),black,0.001)
        inscription("33  /  45",width:0.40,height:0.065,position:SCNVector3(-2.02,0.586,0.99))
        cylinder(0.039,0.009,SCNVector3(-1.73,0.589,1.22),satin)
        powerLens.lightingModel = .physicallyBased;powerLens.roughness.contents=0.24
        let light=cylinder(0.026,0.012,SCNVector3(-1.73,0.597,1.22),powerLens)
        light.name="playback-light";updatePowerLight()
        inscription("POWER",width:0.24,height:0.052,position:SCNVector3(-1.73,0.586,1.34))
        let badge=material(color(0.56,0.52,0.41),metal:0.65,rough:0.5)
        box(0.96,0.115,0.008,SCNVector3(-0.35,0.385,1.555),badge,0.012)
        inscription("RECORD ROOM",width:0.83,height:0.10,position:SCNVector3(-0.35,0.385,1.561),top:false)
    }

    func updatePowerLight(){
        SCNTransaction.begin();SCNTransaction.animationDuration=reducingMotion ? 0:0.45
        powerLens.diffuse.contents=playbackActive ? color(0.85,0.36,0.065):color(0.25,0.12,0.035)
        powerLens.emission.contents=playbackActive ? color(0.65,0.22,0.025):color(0.03,0.012,0.002)
        SCNTransaction.commit()
    }

    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();updateBackingScale()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateBackingScale()}
    func updateBackingScale(){
        let scale=window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if layer?.contentsScale != scale{layer?.contentsScale=scale;needsDisplay=true}
    }
    func build(){
        wantsLayer=true
        scene=world;antialiasingMode = .multisampling4X;preferredFramesPerSecond=30;isPlaying=true;rendersContinuously=false;autoenablesDefaultLighting=false;allowsCameraControl=false
        let floor=SCNFloor();floor.reflectivity=0;floor.materials=[material(color(0.34,0.37,0.38),rough:1)];world.rootNode.addChildNode(SCNNode(geometry:floor))
        let metal=material(color(0.72,0.71,0.65),metal:0.85,rough:0.36)
        let black=material(color(0.025,0.028,0.027),rough:0.32)
        box(4.05,0.29,3.1,SCNVector3(-0.35,0.38,0),walnut,0.06)
        box(3.97,0.055,3.02,SCNVector3(-0.35,0.555,0),metal,0.025)
        for x:Float in [-2.03,1.33]{for z:Float in [-1.22,1.22]{cylinder(0.14,0.24,SCNVector3(x,0.13,z),black)}}
        cylinder(1.32,0.13,SCNVector3(-0.79,0.64,0.06),metal)
        record.position=SCNVector3(-0.79,0.72,0.06);world.rootNode.addChildNode(record)

        discSurface.lightingModel = .physicallyBased;discSurface.metalness.contents=0.03;discSurface.roughness.contents=0.24;discSurface.isDoubleSided=true
        for surface in [discSurface,sleeveFace,discLabel] {surface.diffuse.minificationFilter = .linear;surface.diffuse.magnificationFilter = .linear;surface.diffuse.mipFilter = .linear;surface.diffuse.maxAnisotropy=16}
        discEdge.lightingModel = .physicallyBased;discEdge.metalness.contents=0.02;discEdge.roughness.contents=0.48
        let disc=SCNCylinder(radius:1.28,height:0.026);disc.radialSegmentCount=256;disc.materials=[discEdge,discSurface,discEdge]
        let discNode=SCNNode(geometry:disc);record.addChildNode(discNode)

        // Groove detail lives in the surface texture; tiny torus meshes caused moire at grazing angles.
        discLabel.lightingModel = .physicallyBased;discLabel.roughness.contents=0.8;discLabel.isDoubleSided=true
        let labelPlane=SCNPlane(width:0.77,height:0.77);labelPlane.materials=[discLabel];let lp=SCNNode(geometry:labelPlane);lp.eulerAngles.x = -.pi/2;lp.position.y=0.019;record.addChildNode(lp)
        cylinder(0.022,0.07,SCNVector3(-0.79,0.77,0.06),metal)
        cylinder(0.14,0.12,SCNVector3(1.12,0.66,-1.02),black)
        cylinder(0.11,0.27,SCNVector3(1.12,0.80,-1.02),metal)
        tonearmPivot.position=SCNVector3(1.12,0.94,-1.02)
        tonearmPivot.eulerAngles.y=0.47
        tonearmPivot.addChildNode(tonearmLift);world.rootNode.addChildNode(tonearmPivot)
        rod(SCNVector3(0,0,0),SCNVector3(-0.12,-0.06,1.34),0.027,metal,parent:tonearmLift)
        rod(SCNVector3(-0.12,-0.06,1.34),SCNVector3(-0.84,-0.13,1.95),0.027,metal,parent:tonearmLift)
        buildTurntableDetails(metal:metal,black:black)
        cylinder(0.045,0.16,SCNVector3(1.23,0.66,1.10),black)
        cylinder(0.105,0.075,SCNVector3(-2.02,0.62,1.20),metal)
        box(0.16,0.028,0.055,SCNVector3(1.15,0.602,1.23),black,0.01)
        box(2.05,0.10,0.44,SCNVector3(-3.43,0.10,0.42),walnut)
        sleeveFace.lightingModel = .physicallyBased;sleeveFace.roughness.contents=0.9
        let paper=paperEdge
        let cover=SCNBox(width:1.91,height:1.91,length:0.032,chamferRadius:0.004);cover.materials=[sleeveFace,paper,jacketBack,paper,paper,paper]
        sleeve.geometry=cover;sleeve.position=SCNVector3(-3.43,1.10,0.42);sleeve.eulerAngles=SCNVector3(-0.13,0.22,-0.02);world.rootNode.addChildNode(sleeve)

        configureVinylFinish()
        let cx:Float=3.25,cz:Float=0.2
        box(2.18,0.09,2.12,SCNVector3(cx,0.09,cz),crateWood)
        for y:Float in [0.24,0.48,0.72]{
            box(2.18,0.18,0.09,SCNVector3(cx,y,cz+1.02),crateWood)
            box(2.18,0.18,0.09,SCNVector3(cx,y,cz-1.02),crateWood)
            box(0.09,0.18,2.0,SCNVector3(cx-1.045,y,cz),crateWood)
            box(0.09,0.18,2.0,SCNVector3(cx+1.045,y,cz),crateWood)
        }
        for x in [cx-1.04,cx+1.04]{for z in [cz-1.0,cz+1.0]{box(0.10,0.83,0.10,SCNVector3(x,0.48,z),crateWood)}}
        box(0.71,0.19,0.012,SCNVector3(cx,0.49,cz+1.073),material(color(0.57,0.43,0.22),metal:0.65,rough:0.4),0.014)
        world.rootNode.addChildNode(crateRecords)
        cameraNode.camera=SCNCamera();cameraNode.camera?.usesOrthographicProjection=true;cameraNode.camera?.orthographicScale=6.25;cameraNode.camera?.zNear=0.1;cameraNode.camera?.zFar=40;cameraNode.camera?.wantsDepthOfField=false;cameraNode.camera?.motionBlurIntensity=0;cameraNode.camera?.bloomIntensity=0
        cameraNode.camera?.screenSpaceAmbientOcclusionIntensity=0.22
        cameraNode.camera?.screenSpaceAmbientOcclusionRadius=0.12
        cameraNode.camera?.screenSpaceAmbientOcclusionBias=0.025
        cameraNode.camera?.screenSpaceAmbientOcclusionDepthThreshold=0.3
        world.rootNode.addChildNode(cameraNode);pointOfView=cameraNode
        let light=SCNLight();light.type = .directional;light.intensity=1600;light.castsShadow=true;light.shadowMode = .deferred;light.shadowRadius=2;light.shadowSampleCount=16;light.shadowMapSize=CGSize(width:2048,height:2048);light.shadowColor=NSColor.black.withAlphaComponent(0.40);light.orthographicScale=14
        keyLight.light=light;keyLight.position=SCNVector3(-5,8,4);keyLight.look(at:SCNVector3(0,0,0));world.rootNode.addChildNode(keyLight)
        ambient.light=SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity=550;world.rootNode.addChildNode(ambient)
        buildSpeakers()
        let fillLight=SCNNode();fillLight.name="softbox";fillLight.light=SCNLight();fillLight.light?.type = .omni
        fillLight.light?.intensity=240;fillLight.light?.color=color(0.78,0.86,1)
        fillLight.position=SCNVector3(2,6,-4);world.rootNode.addChildNode(fillLight)
        // A broad, code-drawn studio reflection gives polished surfaces a readable sheen.
        world.lightingEnvironment.contents=NSImage(size:NSSize(width:512,height:256),flipped:false){r in
            fill(r,color(0.19,0.21,0.24));fill(NSRect(x:65,y:90,width:160,height:110),color(0.85,0.88,0.92),radius:28)
            fill(NSRect(x:360,y:110,width:70,height:80),color(0.50,0.53,0.58),radius:20);return true
        }
        world.lightingEnvironment.intensity=0.65
        batchStaticGeometry();applyStyle()
    }

    // Flatten only rigid, unselectable pieces. Moving parts and material controls stay separate.
    func batchStaticGeometry(){
        func merge(_ parent:SCNNode,_ nodes:[SCNNode]){
            guard nodes.count>1 else{return}
            let group=SCNNode();nodes.forEach{group.addChildNode($0)}
            let merged=group.flattenedClone();merged.name="static-detail";parent.addChildNode(merged)
        }
        for speaker in world.rootNode.childNodes where speaker.name=="speaker-cabinet" {
            merge(speaker,speaker.childNodes.filter{node in !speakerCones.contains(where:{$0 === node})})
        }
        let keep=[record,sleeve,crateRecords,tonearmPivot,cameraNode,keyLight,ambient]
        merge(world.rootNode,world.rootNode.childNodes.filter{node in
            !keep.contains(where:{$0 === node}) && node.light==nil && !(node.geometry is SCNFloor) && node.name != "speaker-cabinet" && node.name != "playback-light"
        })
    }
    func setReducedMotion(_ value:Bool){
        guard reducingMotion != value else{return};reducingMotion=value
        if value{
            record.removeAllActions();tonearmPivot.removeAllActions();tonearmLift.removeAllActions()
            world.rootNode.removeAction(forKey:"exchange-out");world.rootNode.removeAction(forKey:"exchange-in")
            crateRecords.childNodes.forEach{$0.removeAllActions()}
            exchanging=false;exchangeWaiting=false;exchangeStarted=nil;pendingCover=nil;armTransitioning=false;armStarted=nil
            record.position.y=mode==1 ? 0.18:0.72;record.opacity=1;sleeve.opacity=1;recordAngularVelocity=0
            updateCurrent();updateCrate(force:true)
        }
        setRecordMotion();setSpeakerMotion();animateTonearm();needsDisplay=true
    }

    func updateRenderingPolicy(visible:Bool){
        let filing=crateRecords.childNodes.contains{$0.action(forKey:"file-sleeve") != nil}
        let transition=Date()<styleTransitionUntil || exchanging || armTransitioning || filing || record.action(forKey:"coast") != nil
        let animate=playbackActive && !reducingMotion || transition
        let fps=transition ? 60:30
        if preferredFramesPerSecond != fps{preferredFramesPerSecond=fps}
        if isPlaying != (visible && animate){isPlaying=visible && animate}
    }

    func applyStyle(){
        let animate=styleApplied && !reducingMotion && (window?.isVisible ?? false)
        styleApplied=true;styleTransitionUntil=animate ? Date(timeIntervalSinceNow:0.28):Date.distantPast
        SCNTransaction.begin();SCNTransaction.animationDuration=animate ? 0.28:0;SCNTransaction.disableActions = !animate
        SCNTransaction.animationTimingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        if animate{isPlaying=true;preferredFramesPerSecond=60}
        let night=sceneStyle==1
        world.background.contents=night ? color(0.055,0.071,0.083):color(0.34,0.37,0.38)
        world.rootNode.childNodes.first(where:{$0.geometry is SCNFloor})?.geometry?.firstMaterial?.diffuse.contents=night ? color(0.08,0.10,0.115):color(0.34,0.37,0.38)
        ambient.light?.intensity=night ? 115:180;ambient.light?.color=night ? color(0.47,0.64,0.85):color(0.96,0.96,0.94)
        keyLight.light?.intensity=night ? 780:1150;keyLight.light?.color=night ? color(1,0.65,0.32):color(1,0.98,0.94)
        cameraNode.position=sceneStyle==2 ? SCNVector3(0,14,0.01):SCNVector3(3.2,8.6,14.5)
        cameraNode.look(at:SCNVector3(0,0.45,0));cameraNode.camera?.orthographicScale=sceneStyle==2 ? 6.3:6.05
        world.lightingEnvironment.intensity=night ? 0.22:0.32
        world.rootNode.childNode(withName:"softbox",recursively:false)?.light?.intensity=night ? 65:150
        SCNTransaction.commit();needsDisplay=true
    }

    func palette(from image: NSImage) -> [NSColor] {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return [color(0.10,0.10,0.10), color(0.78,0.78,0.78), color(0.44,0.44,0.44)]
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let steps = 12
        var samples: [NSColor] = []
        for y in stride(from: 0, to: h, by: max(1,h/steps)) {
            for x in stride(from: 0, to: w, by: max(1,w/steps)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let b = (c.redComponent*0.299)+(c.greenComponent*0.587)+(c.blueComponent*0.114)
                if b > 0.06 && b < 0.95 { samples.append(c) }
            }
        }
        if samples.isEmpty { return [color(0.10,0.10,0.10), color(0.78,0.78,0.78), color(0.44,0.44,0.44)] }
        samples.sort {
            let l0 = $0.redComponent*0.299 + $0.greenComponent*0.587 + $0.blueComponent*0.114
            let l1 = $1.redComponent*0.299 + $1.greenComponent*0.587 + $1.blueComponent*0.114
            return l0 < l1
        }
        let dark = samples[samples.count/6]
        let mid = samples[samples.count/2]
        let bright = samples[min(samples.count-1, (samples.count*5)/6)]
        let vivid=samples.max{ $0.saturationComponent < $1.saturationComponent } ?? mid
        return [dark, vivid, bright]
    }

    func mixed(_ a: NSColor, _ b: NSColor, _ t: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let a = a.usingColorSpace(.deviceRGB) ?? a
        let b = b.usingColorSpace(.deviceRGB) ?? b
        return color(a.redComponent + (b.redComponent-a.redComponent)*t, a.greenComponent + (b.greenComponent-a.greenComponent)*t, a.blueComponent + (b.blueComponent-a.blueComponent)*t, alpha)
    }

    func variant(for album: NSImage, key: String) -> VinylVariant {
        var rng = SeededGenerator(seed: hashSeed(key))
        let roll=rng.int(100)
        let style:VinylVariant.Style = roll < 48 ? .black : roll < 63 ? .twotone : roll < 78 ? .marble : roll < 93 ? .splatter : .translucent
        let colors=palette(from:album)
        let black=color(0.022,0.025,0.027)
        let vivid=colors[1].usingColorSpace(.deviceRGB) ?? colors[1]
        let ink=NSColor(calibratedHue:vivid.hueComponent,saturation:min(0.88,max(0.30,vivid.saturationComponent)),brightness:min(0.72,max(0.36,vivid.brightnessComponent)),alpha:1)
        let pearl=mixed(colors[2],color(0.92,0.94,0.95),rng.range(0.45,0.72))
        let base = style == .black || style == .splatter ? black : ink
        return VinylVariant(style:style,base:base,accent:style == .twotone ? mixed(ink,black,0.78) : (style == .splatter ? mixed(ink,pearl,0.32) : pearl),accent2:mixed(ink,black,0.30),translucent:style == .translucent)
    }

    private var armTarget:CGFloat { -0.08 - 0.30 * songFraction }
    func updatePlayback(playing:Bool,fraction:CGFloat,track:String){
        let changed = !playbackTrack.isEmpty && playbackTrack != track
        let toggled = playbackActive != playing
        playbackTrack=track;songFraction=min(1,max(0,fraction))
        if toggled {playbackActive=playing;setSpeakerMotion();updatePowerLight()}
        if reducingMotion{tonearmPivot.eulerAngles.y=playing ? armTarget:0.47;tonearmLift.eulerAngles.x=0;return}
        recoverMotionIfNeeded()
        if exchanging{return}
        if toggled{setRecordMotion()}
        if toggled || (changed && playing){animateTonearm()}
        else if playing && !armTransitioning {trackGroove()}
    }
    func trackGroove(){
        guard !reducingMotion else{return}
        let from=tonearmPivot.presentation.eulerAngles.y
        tonearmPivot.removeAction(forKey:"tracking");tonearmPivot.eulerAngles.y=from
        // Predict the next sample rather than moving and stopping at every poll.
        let target:CGFloat = -0.08 - 0.30 * min(1,songFraction+CGFloat(2/max(1,playbackDuration)))
        let action=SCNAction.rotateTo(x:0,y:target,z:0,duration:2.0,usesShortestUnitArc:true)
        action.timingMode = .linear;tonearmPivot.runAction(action,forKey:"tracking")
    }
    func animateTonearm(park:Bool=false){
        if reducingMotion{tonearmPivot.eulerAngles.y=playbackActive && !park ? armTarget:0.47;tonearmLift.eulerAngles.x=0;return}
        let yaw=tonearmPivot.presentation.eulerAngles.y
        let tilt=tonearmLift.presentation.eulerAngles.x
        tonearmPivot.removeAllActions();tonearmLift.removeAllActions()
        tonearmPivot.eulerAngles.y=yaw;tonearmLift.eulerAngles.x=tilt
        // The lift rotates around the gimbal; it never translates away from it.
        tonearmLift.position = SCNVector3Zero
        armTransitioning=true;armStarted=Date()
        let target:CGFloat=playbackActive && !park ? armTarget : 0.47
        let sweep=SCNAction.customAction(duration:1.15){[weak self] _,elapsed in
            guard let s=self else{return};let t=min(1,elapsed/1.15);let u=t*t*(3-2*t)
            s.tonearmPivot.eulerAngles.y=yaw+(target-yaw)*u
            s.tonearmLift.eulerAngles.x=tilt*(1-u)-0.085*sin(.pi*u)
        }
        tonearmPivot.runAction(sweep,forKey:"transition"){[weak self] in
            guard let s=self else{return};s.armTransitioning=false;s.armStarted=nil
            s.tonearmLift.eulerAngles.x=0
            if s.playbackActive && !s.exchanging{s.trackGroove()}
        }
    }
    func setRecordMotion(running:Bool?=nil){
        let start=record.presentation.eulerAngles.y, initialSpeed=recordAngularVelocity
        record.removeAllActions();record.eulerAngles.y=start
        if reducingMotion{recordAngularVelocity=0;return}
        let speed:CGFloat = .pi*2/1.8
        if running ?? playbackActive{
            let ramp=SCNAction.customAction(duration:0.45){[weak self] node,t in
                node.eulerAngles.y=start+initialSpeed*t+(speed-initialSpeed)*t*t/0.9
                self?.recordAngularVelocity=initialSpeed+(speed-initialSpeed)*min(1,t/0.45)
            }
            record.runAction(.sequence([ramp,.repeatForever(.rotateBy(x:0,y:.pi*2,z:0,duration:1.8))]),forKey:"spin")
        }else{
            record.runAction(.customAction(duration:0.45){[weak self] node,t in
                node.eulerAngles.y=start+initialSpeed*(t-t*t/0.9)
                self?.recordAngularVelocity=initialSpeed*max(0,1-t/0.45)
            },forKey:"coast")
        }
    }
    func setSpeakerMotion(){
        for (i,cone) in speakerCones.enumerated(){
            let rest=coneRestDepth[i];cone.removeAllActions()
            if playbackActive && !reducingMotion{
                let wave=SCNAction.customAction(duration:30){node,t in
                    let phase=CGFloat(i)*0.37
                    node.position.z=rest+0.004*(sin(t*(.pi*2*91/30)+phase)+0.35*sin(t*(.pi*2*148/30)+phase))
                }
                cone.runAction(.repeatForever(wave),forKey:"pulse")
            }else{
                let target=SCNVector3(cone.position.x,cone.position.y,rest)
                let settle=SCNAction.move(to:target,duration:0.45);settle.timingMode = .easeOut;cone.runAction(settle)
            }
        }
    }
    func buildSpeakers(){
        let baffle=material(color(0.075,0.073,0.066),rough:0.96)
        // Analytic weave softens at a distance to avoid shimmering on iPad.
        baffle.shaderModifiers=[.surface:"""
        float2 p = _surface.diffuseTexcoord * float2(115.0, 240.0);
        float2 footprint = fwidth(p);
        float fade = 1.0 - smoothstep(0.25, 0.75, max(footprint.x, footprint.y));
        float weave = sin(p.x * 6.28318) * sin(p.y * 6.28318);
        _surface.diffuse.rgb *= 1.0 + 0.10 * weave * fade;
        """]
        let rubber=material(color(0.035,0.037,0.034),rough:0.88)
        let paper=material(color(0.105,0.109,0.097),rough:0.93)
        let trim=material(color(0.15,0.16,0.15),metal:0.7,rough:0.42)
        let badge=material(color(0.49,0.43,0.32),metal:0.8,rough:0.38)
        for x:CGFloat in [-5.15,5.15]{
            let speaker=SCNNode();speaker.name="speaker-cabinet"
            speaker.position=SCNVector3(x,0,-0.60)
            speaker.eulerAngles.y=x<0 ? 0.12 : -0.12
            world.rootNode.addChildNode(speaker)
            // The back stops behind the recessed front; wood rails frame the drivers.
            box(1.06,2.12,0.86,SCNVector3(0,1.16,-0.07),speakerWood,0.035,parent:speaker)
            box(0.95,2.01,0.025,SCNVector3(0,1.16,0.375),baffle,0.012,parent:speaker)
            for side:CGFloat in [-1,1]{
                box(0.065,2.08,0.15,SCNVector3(side*0.4975,1.16,0.425),speakerWood,0.018,parent:speaker)
                box(0.97,0.065,0.15,SCNVector3(0,1.16+side*1.0275,0.425),speakerWood,0.018,parent:speaker)
            }
            for (y,r) in [(CGFloat(0.85),CGFloat(0.32)),(CGFloat(1.69),CGFloat(0.135))]{
                func ring(_ radius:CGFloat,_ thickness:CGFloat,_ depth:CGFloat,_ mat:SCNMaterial){
                    let g=SCNTorus(ringRadius:radius,pipeRadius:thickness);g.ringSegmentCount=80;g.pipeSegmentCount=12;g.materials=[mat]
                    let n=SCNNode(geometry:g);n.eulerAngles.x = .pi/2;n.position=SCNVector3(0,y,depth);speaker.addChildNode(n)
                }
                ring(r*1.10,0.012,0.421,trim)
                ring(r, r*0.085,0.435,rubber)
                // A concave paper diaphragm, with its centre behind the surround.
                let segments=80
                var vertices:[SCNVector3]=[],normals:[SCNVector3]=[],indices:[Int32]=[]
                for (radius,depth) in [(r*0.22,CGFloat(-0.035)),(r*0.91,CGFloat(0.015))]{
                    for i in 0...segments{
                        let angle=CGFloat(i)*2 * .pi/CGFloat(segments)
                        vertices.append(SCNVector3(radius*cos(angle),radius*sin(angle),depth))
                        normals.append(SCNVector3(-0.2*cos(angle),-0.2*sin(angle),0.98))
                    }
                }
                for i in 0..<segments{let a=Int32(i),b=Int32(i+segments+1);indices += [a,b,a+1,a+1,b,b+1]}
                let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
                geometry.materials=[paper]
                let node=SCNNode(geometry:geometry);node.position=SCNVector3(0,y,0.415);speaker.addChildNode(node)
                let cap=SCNSphere(radius:r*0.24);cap.segmentCount=32;cap.materials=[rubber]
                let capNode=SCNNode(geometry:cap);capNode.position=SCNVector3(0,0,-0.027);capNode.scale=SCNVector3(1,1,0.35);node.addChildNode(capNode)
                speakerCones.append(node);coneRestDepth.append(node.position.z)
            }
            box(0.21,0.045,0.008,SCNVector3(0,0.30,0.397),badge,0.006,parent:speaker)
            for side:CGFloat in [-1,1]{for depth:CGFloat in [-0.31,0.31]{
                cylinder(0.065,0.10,SCNVector3(side*0.36,0.05,depth),rubber,parent:speaker)
            }}
        }
    }

    func drawSpeckles(in rect: NSRect, rng: inout SeededGenerator, color: NSColor, count: Int, size: ClosedRange<CGFloat>, alpha: ClosedRange<CGFloat>) {
        for _ in 0..<count {
            let s = rng.range(size.lowerBound, size.upperBound)
            let x = rng.range(rect.minX, rect.maxX-s)
            let y = rng.range(rect.minY, rect.maxY-s)
            oval(NSRect(x:x,y:y,width:s,height:s), color.withAlphaComponent(rng.range(alpha.lowerBound, alpha.upperBound)))
        }
    }

    func drawMarble(in rect:NSRect,rng:inout SeededGenerator,colors:[NSColor],swirl:CGFloat){
        let size=512
        guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32),let bytes=rep.bitmapData else{return}
        let phase=Double(rng.range(0,6.28)),frequency=Double(rng.range(12,21))
        let ink=colors[0].usingColorSpace(.deviceRGB)!,vein=colors[1].usingColorSpace(.deviceRGB)!
        let a=[Double(ink.redComponent),Double(ink.greenComponent),Double(ink.blueComponent)]
        let b=[Double(vein.redComponent),Double(vein.greenComponent),Double(vein.blueComponent)]
        for y in 0..<size {for x in 0..<size {
            let u=Double(x)/Double(size),v=Double(y)/Double(size)
            let flow=u*frequency+3.8*sin(v*6+phase)+1.6*sin(u*7-v*9+phase)+0.55*sin(u*23+v*18)
            let wave=abs(sin(flow)),veining=pow(wave,36)*0.18
            let shade=0.88+0.12*sin(u*5+v*7+phase)
            let offset=y*rep.bytesPerRow+x*4
            for c in 0..<3 {bytes[offset+c]=UInt8(max(0,min(255,255*(a[c]*shade*(1-veining)+b[c]*veining))))}
            bytes[offset+3]=255
        }}
        let image=NSImage(size:NSSize(width:size,height:size));image.addRepresentation(rep);image.draw(in:rect)
    }

    func drawPinwheel(in rect: NSRect, rng: inout SeededGenerator, colors: [NSColor]) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let wedges = 3 + rng.int(16)
        for i in 0..<wedges {
            let start = (CGFloat(i) / CGFloat(wedges)) * .pi * 2
            let end = start + (.pi * 2 / CGFloat(wedges)) * rng.range(0.65, 1.15)
            let p = NSBezierPath()
            p.move(to: center)
            p.appendArc(withCenter: center, radius: rect.width*0.5, startAngle: start * 180 / .pi, endAngle: end * 180 / .pi)
            p.close()
            colors[i % colors.count].withAlphaComponent(rng.range(0.18, 0.42)).setFill()
            p.fill()
        }
    }

    func drawSmoke(in rect: NSRect, rng: inout SeededGenerator, colors: [NSColor]) {
        for i in 0..<18 {
            let w = rng.range(rect.width*0.24, rect.width*0.72)
            let h = rng.range(rect.height*0.08, rect.height*0.22)
            let x = rng.range(rect.minX - w*0.15, rect.maxX - w*0.85)
            let y = rng.range(rect.minY, rect.maxY-h)
            let blob = NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h), xRadius: h*0.6, yRadius: h*0.6)
            colors[i % colors.count].withAlphaComponent(rng.range(0.07, 0.18)).setFill()
            blob.fill()
        }
    }

    func makeVinylTexture(album: NSImage, key: String) -> NSImage {
        let variant = variant(for: album, key: key)
        let size = NSSize(width: 1600, height: 1600)
        return NSImage(size: size, flipped: false) { [self] rect in
            let discRect = rect.insetBy(dx: 1, dy: 1)
            let discPath = NSBezierPath(ovalIn: discRect)
            discPath.addClip()
            let outerGlow = variant.style == .black ? variant.base : mixed(variant.base, variant.accent, 0.05)
            let core = variant.translucent ? mixed(variant.base, variant.accent2, 0.35, alpha: 0.92) : variant.base
            NSGradient(colors: [outerGlow.withAlphaComponent(1), core.withAlphaComponent(1)])?.draw(in: discPath, relativeCenterPosition: NSPoint(x:0.15,y:0.2))
            var rng = SeededGenerator(seed: hashSeed(key + "-vinyl"))
            switch variant.style {
            case .black:
                break
            case .translucent:
                drawMarble(in: discRect, rng: &rng, colors: [variant.base, mixed(variant.base,variant.accent2,0.20)], swirl: 2)
                drawSpeckles(in: discRect, rng: &rng, color: .white, count: 70, size: 1...3, alpha: 0.02...0.05)
            case .splatter:
                drawSpeckles(in: discRect, rng: &rng, color: variant.accent, count: 75, size: 3...17, alpha: 0.55...0.90)
                drawSpeckles(in: discRect, rng: &rng, color: variant.accent2, count: 35, size: 2...8, alpha: 0.40...0.70)
            case .marble:
                drawMarble(in: discRect, rng: &rng, colors: [variant.base, variant.accent], swirl: rng.range(2.8, 6.7))
            case .smoke:
                drawSmoke(in: discRect, rng: &rng, colors: [variant.accent, variant.accent2, mixed(variant.base, .black, 0.25)])
                drawMarble(in: discRect, rng: &rng, colors: [variant.accent.withAlphaComponent(0.5), variant.accent2.withAlphaComponent(0.45)], swirl: rng.range(1.6, 3.1))
            case .pinwheel:
                drawPinwheel(in: discRect, rng: &rng, colors: [variant.accent, variant.accent2, mixed(variant.base, .white, 0.15)])
            case .twotone:
                // Two PVC halves join through the spindle, with a restrained organic seam.
                NSGraphicsContext.saveGraphicsState()
                let transform=NSAffineTransform();transform.translateX(by:rect.midX,yBy:rect.midY);transform.rotate(byDegrees:rng.range(-40,40));transform.translateX(by:-rect.midX,yBy:-rect.midY);transform.concat()
                let seam=NSBezierPath();seam.move(to:NSPoint(x:-400,y:-400));seam.line(to:NSPoint(x:rect.midX,y:-400))
                seam.line(to:NSPoint(x:rect.midX,y:0));seam.curve(to:NSPoint(x:rect.midX,y:rect.height),controlPoint1:NSPoint(x:rect.midX-14,y:rect.height*0.33),controlPoint2:NSPoint(x:rect.midX+14,y:rect.height*0.67))
                seam.line(to:NSPoint(x:rect.midX,y:rect.height+400));seam.line(to:NSPoint(x:-400,y:rect.height+400));seam.close()
                variant.accent.setFill();seam.fill();NSGraphicsContext.restoreGraphicsState()

            }
            for i in 0..<48 {
                let inset = CGFloat(i) * 8.6
                let groove = discRect.insetBy(dx: 120 + inset, dy: 120 + inset)
                guard groove.width > 150 else { continue }
                (variant.style == .black ? NSColor.white.withAlphaComponent(0.025) : NSColor.black.withAlphaComponent(i < 4 ? 0.10 : 0.07)).setStroke()
                let p = NSBezierPath(ovalIn: groove)
                p.lineWidth = 1.5
                p.stroke()
            }
            NSColor.white.withAlphaComponent(0.045).setStroke()
            let sheen = NSBezierPath(ovalIn: discRect.insetBy(dx: 58, dy: 58)); sheen.lineWidth = 2; sheen.stroke()
            let cutout = NSRect(x: rect.midX-18, y: rect.midY-18, width: 36, height: 36)
            NSColor(calibratedWhite: 0.02, alpha: 0.92).setFill(); NSBezierPath(ovalIn: cutout).fill()
            return true
        }
    }

    func bakeImage(_ image:NSImage,width:Int,height:Int)->CGImage?{
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{return nil}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        image.draw(in:NSRect(x:0,y:0,width:width,height:height));NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    func preparedPressing(_ art:NSImage,key:String)->PreparedPressing? {
        let cacheKey=(key.isEmpty ? "record-room-placeholder":key) as NSString
        if let cached=Self.pressingCache.object(forKey:cacheKey){return cached}
        let variant=variant(for:art,key:cacheKey as String)
        let texture=makeVinylTexture(album:art,key:cacheKey as String)
        let label=NSImage(size:NSSize(width:512,height:512),flipped:false){r in
            NSBezierPath(ovalIn:r).addClip();art.draw(in:r)
            NSColor.white.withAlphaComponent(0.24).setStroke();let ring=NSBezierPath(ovalIn:r.insetBy(dx:12,dy:12));ring.lineWidth=1.5;ring.stroke()
            oval(NSRect(x:r.midX-7,y:r.midY-7,width:14,height:14),color(0.025,0.025,0.025));return true
        }
        guard let pixels=bakeImage(texture,width:1600,height:1600),
              let labelPixels=bakeImage(label,width:512,height:512),
              let cover=bakeImage(art,width:1024,height:1024) else{return nil}
        let result=PreparedPressing(variant,pixels,labelPixels,cover)
        Self.pressingCache.setObject(result,forKey:cacheKey,cost:pixels.bytesPerRow*pixels.height+labelPixels.bytesPerRow*labelPixels.height+cover.bytesPerRow*cover.height);return result
    }

    func recoverMotionIfNeeded(){
        if exchanging,let started=exchangeStarted,Date().timeIntervalSince(started)>6 {
            world.rootNode.removeAction(forKey:"exchange-out");world.rootNode.removeAction(forKey:"exchange-in")
            exchanging=false;exchangeWaiting=false;exchangeStarted=nil;pendingCover=nil
            record.position.y=0.72;record.opacity=1;sleeve.opacity=1
            if let art=album,readyPressing?.key==currentKey || Self.pressingCache.object(forKey:currentKey as NSString) != nil {
                updateCrate(force:true);applyArtwork(art,key:currentKey)
            }
            setRecordMotion();animateTonearm()
        }else if !exchanging,armTransitioning,let started=armStarted,Date().timeIntervalSince(started)>2.5 {
            tonearmPivot.removeAllActions();tonearmLift.eulerAngles.x=0
            tonearmPivot.eulerAngles.y=playbackActive ? armTarget:0.47
            armTransitioning=false;armStarted=nil
            if playbackActive{trackGroove()}
        }
    }

    func updateCurrent(){
        guard let artwork=album else{return}
        let key=currentKey.isEmpty ? "record-room-placeholder":currentKey
        let interactive=window != nil && !CommandLine.arguments.contains("--render-previews") && !CommandLine.arguments.contains("--export-demo")
        if interactive && preparingKey==key{return}
        if interactive && ((readyPressing?.key != key && Self.pressingCache.object(forKey:key as NSString)==nil) || gpuReadyKey != key){
            preparationTicket?.cancel();let ticket=ArtworkTicket();preparationTicket=ticket;preparingKey=key
            Self.textureQueue.async{[weak self] in
                guard !ticket.isCancelled,let s=self,let prepared=s.preparedPressing(artwork,key:key),!ticket.isCancelled else{return}
                DispatchQueue.main.async{[weak self] in
                    guard let s=self,!ticket.isCancelled,(s.currentKey.isEmpty ? "record-room-placeholder":s.currentKey)==key else{return}
                    guard s.album.map({ObjectIdentifier($0)})==ObjectIdentifier(artwork) else{
                        Self.pressingCache.removeObject(forKey:key as NSString);s.preparingKey=nil;s.updateCurrent();return
                    }
                    let cover=s.sleeveFace.copy() as! SCNMaterial;cover.diffuse.contents=prepared.cover
                    let vinyl=s.discSurface.copy() as! SCNMaterial;vinyl.diffuse.contents=prepared.texture
                    let label=s.discLabel.copy() as! SCNMaterial;label.diffuse.contents=prepared.label
                    s.prepare([cover,vinyl,label]){[weak s] _ in DispatchQueue.main.async{[weak s] in
                        guard let s=s,!ticket.isCancelled,(s.currentKey.isEmpty ? "record-room-placeholder":s.currentKey)==key else{return}
                        s.readyPressing=(key,prepared);s.preparingKey=nil;s.gpuReadyKey=key;s.updateCurrent()
                    }}
                }
            };return
        }
        if readyPressing?.key != key{guard let value=Self.pressingCache.object(forKey:key as NSString) ?? preparedPressing(artwork,key:key) else{return};readyPressing=(key,value)}
        if exchanging {
            pendingCover=(currentKey,artwork)
            if exchangeWaiting{installPendingRecord()}
            return
        }
        if lastArtworkIdentity==ObjectIdentifier(artwork) && lastArtworkKey==currentKey{return}
        if mode==0 && !reducingMotion && window != nil && !lastArtworkKey.isEmpty && lastArtworkKey != currentKey {
            pendingCover=(currentKey,artwork);beginRecordExchange();return
        }
        applyArtwork(artwork,key:currentKey)
    }

    func beginRecordExchange(){
        exchanging=true;exchangeWaiting=false;exchangeStarted=Date()
        animateTonearm(park:true);setRecordMotion(running:false)
        // Separate the visual exchange from the player's audio and state polling.
        world.rootNode.runAction(.sequence([
            .wait(duration:1.15),
            .run({[weak self] _ in
                guard let s=self else{return}
                s.updateCrate(force:true);s.sleeve.opacity=0
            },queue:.main),
            .customAction(duration:0.45){[weak self] _,elapsed in
                guard let s=self else{return};let t=min(1,elapsed/0.45),u=t*t*t*(t*(t*6-15)+10)
                s.record.position.y=0.72+0.48*u;s.record.opacity=1-pow(max(0,(u-0.35)/0.65),2)
            },
            .run({[weak self] _ in
                guard let s=self else{return};s.exchangeWaiting=true;s.installPendingRecord()
            },queue:.main)
        ]),forKey:"exchange-out")
    }

    func installPendingRecord(){
        guard exchangeWaiting,let next=pendingCover,next.key==currentKey else{return}
        exchangeWaiting=false;pendingCover=nil
        updateCrate(force:true);applyArtwork(next.art,key:next.key)
        record.eulerAngles.y=0;recordAngularVelocity=0
        world.rootNode.runAction(.sequence([
            .customAction(duration:0.60){[weak self] _,elapsed in
                guard let s=self else{return};let t=min(1,elapsed/0.60),u=t*t*t*(t*(t*6-15)+10)
                s.record.position.y=1.20-0.48*u
                let reveal=min(1,elapsed/0.18);s.record.opacity=reveal*reveal*(3-2*reveal)
                let cover=min(1,elapsed/0.30);s.sleeve.opacity=cover*cover*(3-2*cover)
            },
            .run({[weak self] _ in
                guard let s=self else{return}
                s.record.position.y=0.72;s.record.opacity=1;s.sleeve.opacity=1;s.exchanging=false;s.exchangeStarted=nil
                if let pending=s.pendingCover,pending.key==s.currentKey,pending.key != s.lastArtworkKey {
                    s.beginRecordExchange()
                }else{
                    s.pendingCover=nil;s.setRecordMotion();s.animateTonearm()
                }
            },queue:.main)
        ]),forKey:"exchange-in")
    }

    func applyArtwork(_ album:NSImage,key:String){
        lastArtworkIdentity=ObjectIdentifier(album);lastArtworkKey=key
        sleeveFace.diffuse.contents=album;sleeve.name="album:"+key
        let cacheKey = key.isEmpty ? "record-room-placeholder" : key
        guard let prepared=(readyPressing?.key==cacheKey ? readyPressing?.value:nil) ?? Self.pressingCache.object(forKey:cacheKey as NSString) else{return}
        sleeveFace.diffuse.contents=prepared.cover
        discSurface.diffuse.contents=prepared.texture
        discSurface.emission.contents=NSColor.black
        discSurface.roughness.intensity=prepared.variant.style == .black ? 0.85:1
        discEdge.diffuse.contents=mixed(prepared.variant.base,.black,0.18)
        discLabel.diffuse.contents=prepared.label
        needsDisplay=true
    }

    // One continuous path with zero velocity and acceleration at both ends.
    func filingPose(from start:SCNVector3,angles:SCNVector3,to end:SCNVector3,fraction:CGFloat)->(SCNVector3,SCNVector3){
        let t=max(0,min(1,fraction)),u=t*t*t*(t*(t*6-15)+10)
        let travel=max(0,min(1,(t-0.16)/0.58)),v=travel*travel*travel*(travel*(travel*6-15)+10)
        return (SCNVector3(start.x+(end.x-start.x)*v,start.y+(end.y-start.y)*u+2.1*sin(.pi*u),start.z+(end.z-start.z)*v),
                SCNVector3(angles.x+(-0.075-angles.x)*v,angles.y*(1-v),angles.z*(1-v)))
    }

    func updateCrate(force:Bool=false){
        if !force && window != nil && !lastArtworkKey.isEmpty && lastArtworkKey != currentKey{return}
        let history=Array(stack.filter{$0.key != currentKey}.suffix(14))
        crateKeys=Set(history.map(\.key))
        for node in crateRecords.childNodes {
            if let name=node.name,!crateKeys.contains(String(name.dropFirst(6))){node.removeFromParentNode()}
        }
        for (i,item) in history.enumerated(){
            let name="album:"+item.key
            let existing=crateRecords.childNode(withName:name,recursively:false)
            let n=existing ?? SCNNode()
            let destination=SCNVector3(3.25,1.10,-0.65+Double(i)*0.12)
            if existing == nil {
                let front=material(.white,rough:0.9);front.diffuse.contents=item.art;front.roughness.contents=sleeveFace.roughness.contents
                let paper=paperEdge
                let g=SCNBox(width:1.90,height:1.90,length:0.025,chamferRadius:0.004)
                g.materials=[front,paper,jacketBack,paper,paper,paper];n.geometry=g;n.name=name
                n.position=destination;n.eulerAngles=SCNVector3(-0.075,0,0);crateRecords.addChildNode(n)
                if !reducingMotion && window != nil && item.key == lastArtworkKey {
                    n.position=sleeve.position;n.eulerAngles=sleeve.eulerAngles
                    let start=n.position,angles=n.eulerAngles
                    n.runAction(.customAction(duration:1.55){node,time in
                        let pose=self.filingPose(from:start,angles:angles,to:destination,fraction:time/1.55)
                        node.position=pose.0;node.eulerAngles=pose.1
                    },forKey:"file-sleeve")
                }
            }else if n.action(forKey:"file-sleeve")==nil {
                n.position=destination;n.eulerAngles=SCNVector3(-0.075,0,0)
            }
        }
        needsDisplay=true
    }

    func configureInspection(){
        mode=1;isPlaying=false;preferredFramesPerSecond=60
        for node in world.rootNode.childNodes {
            node.isHidden = !(node === record || node === sleeve || node === cameraNode || node.light != nil || node.geometry is SCNFloor)
        }
        record.position=SCNVector3(0.9,0.18,0.4)
        sleeve.position=SCNVector3(-1.65,1.04,-0.35);sleeve.eulerAngles=SCNVector3(-0.08,0.10,0)
        cameraNode.position=SCNVector3(0,6,8);cameraNode.look(at:SCNVector3(0,0.5,0));cameraNode.camera?.orthographicScale=3.0
        allowsCameraControl=true;defaultCameraController.target=SCNVector3(0,0.5,0)
        defaultCameraController.minimumVerticalAngle=18;defaultCameraController.maximumVerticalAngle=85
        defaultCameraController.inertiaEnabled=true
    }

    override func mouseDown(with event:NSEvent){
        if mode==1{super.mouseDown(with:event);return}
        let p=convert(event.locationInWindow,from:nil)
        if let hit=hitTest(p,options:nil).first,let name=hit.node.name,name.hasPrefix("album:"){onSelect?(String(name.dropFirst(6)))}
    }
}

final class SessionGalleryItem:NSCollectionViewItem{
    var open:(()->Void)?
    let art=NSImageView(),titleLabel=NSTextField(labelWithString:""),artistLabel=NSTextField(labelWithString:"")
    override func loadView(){
        let button=NSButton(frame:NSRect(x:0,y:0,width:190,height:250));button.isBordered=false;button.title="";button.target=self;button.action=#selector(choose)
        art.frame=NSRect(x:7,y:65,width:176,height:176);art.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.frame=NSRect(x:7,y:28,width:176,height:34);titleLabel.maximumNumberOfLines=2;titleLabel.font = .systemFont(ofSize:13,weight:.semibold)
        artistLabel.frame=NSRect(x:7,y:8,width:176,height:18);artistLabel.font = .systemFont(ofSize:11);artistLabel.textColor = .secondaryLabelColor
        for child in [art,titleLabel,artistLabel] as [NSView]{child.setAccessibilityElement(false);button.addSubview(child)}
        view=button
    }
    func configure(_ album:Album,open:@escaping()->Void){
        _=view;self.open=open;art.image=album.art;titleLabel.stringValue=album.title;artistLabel.stringValue=album.artist
        view.setAccessibilityLabel("\(album.title), \(album.artist). Inspect record.")
    }
    @objc func choose(){open?()}
}
final class SessionGallery:NSObject,NSCollectionViewDataSource{
    let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:850,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let grid=NSCollectionView(),summary=NSTextField(labelWithString:""),exportButton=NSButton(title:"Save session image…",target:nil,action:nil)
    var albums:[Album]=[],signature="",onInspect:((String)->Void)?,onExport:(()->Void)?
    override init(){
        super.init();panel.title="Your listening session";panel.minSize=NSSize(width:460,height:480);panel.isReleasedWhenClosed=false;panel.animationBehavior = .utilityWindow
        let content=panel.contentView!
        summary.frame=NSRect(x:24,y:602,width:780,height:28);summary.font = .systemFont(ofSize:19,weight:.semibold);summary.autoresizingMask=[.width,.minYMargin];content.addSubview(summary)
        let scroll=NSScrollView(frame:NSRect(x:16,y:76,width:818,height:516));scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let layout=NSCollectionViewFlowLayout();layout.itemSize=NSSize(width:190,height:250);layout.minimumInteritemSpacing=8;layout.minimumLineSpacing=10;layout.sectionInset=NSEdgeInsets(top:0,left:8,bottom:16,right:8)
        grid.collectionViewLayout=layout;grid.dataSource=self;grid.backgroundColors=[.clear];grid.register(SessionGalleryItem.self,forItemWithIdentifier:NSUserInterfaceItemIdentifier("album"));grid.frame=scroll.contentView.bounds;grid.autoresizingMask=[.width];scroll.documentView=grid;content.addSubview(scroll)
        exportButton.target=self;exportButton.action=#selector(export);exportButton.bezelStyle = .rounded;exportButton.frame=NSRect(x:24,y:38,width:180,height:30);content.addSubview(exportButton)
        let note=NSTextField(labelWithString:"Saved locally. The image includes album artwork and names; you choose what to share.");note.font = .systemFont(ofSize:10);note.textColor = .secondaryLabelColor;note.frame=NSRect(x:24,y:10,width:800,height:20);note.autoresizingMask=[.width];content.addSubview(note)
    }
    func update(_ values:[Album]){
        let next=values.map{"\($0.key)|\(ObjectIdentifier($0.art))"}.joined(separator:";")
        guard signature != next || albums.isEmpty else{return};signature=next;albums=values
        summary.stringValue=values.isEmpty ? "Your next album starts the collection":"\(values.count) albums · this listening session"
        exportButton.isEnabled = !values.isEmpty;grid.reloadData()
    }
    func collectionView(_ collectionView:NSCollectionView,numberOfItemsInSection section:Int)->Int{albums.count}
    func collectionView(_ collectionView:NSCollectionView,itemForRepresentedObjectAt indexPath:IndexPath)->NSCollectionViewItem{
        let item=collectionView.makeItem(withIdentifier:NSUserInterfaceItemIdentifier("album"),for:indexPath) as! SessionGalleryItem
        let album=albums[albums.count-1-indexPath.item];item.configure(album){[weak self] in self?.onInspect?(album.key)};return item
    }
    @objc func export(){onExport?()}
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    var inspection:NSPanel?
    var gallery:SessionGallery?
    var status:NSStatusItem!; var panel:NSPanel!;var preview:RoomView!;var desktopWindows:[NSWindow]=[];var desktopViews:[RoomView]=[]
    var titleField:NSTextField!;var artistField:NSTextField!;var progress:NSProgressIndicator!;var timeField:NSTextField!;var sessionField:NSTextField!;var stateField:NSTextField!
    var albums:[Album]=[];var currentKey="";var currentArt:NSImage?;var playing=false;var position=0.0;var duration=1.0;var positionSampledAt=Date();var currentTrackIdentity="";var source="";var lastError="";var pollBusy=false;var enabled=prefs.bool(forKey:"musicEnabled")
    var scene=prefs.integer(forKey:"scene");var hidePaused=prefs.bool(forKey:"hidePaused");var active=(prefs.object(forKey:"roomVisible") as? Bool ?? true);var angle:CGFloat=0
    var artworkRetryAt=Date.distantPast,artworkAttempts=0,missingArtworkKey:String?
    var renderingSuspended=false
    let musicQueue=DispatchQueue(label:"recordroom.music");var artTask:URLSessionDataTask?;var pollTimer:Timer?;var animationTimer:Timer?
    var placeholder:NSImage {
        NSImage(size:NSSize(width:600,height:600),flipped:false){r in
            fill(r,color(0.12,0.18,0.17));NSGradient(starting:color(0.80,0.41,0.22),ending:color(0.07,0.18,0.21))!.draw(in:r,angle:35)
            for i in 0..<30 {let n=CGFloat(i);oval(NSRect(x:70+n*4,y:70+n*4,width:460-n*8,height:460-n*8),color(0.02,0.07,0.08,0.055))}
            label("RECORD",NSRect(x:55,y:470,width:500,height:65),53,color(0.94,0.87,0.70),.light)
            label("ROOM",NSRect(x:55,y:408,width:500,height:65),53,color(0.94,0.87,0.70),.light)
            label("SIDE A  /  YOUR LISTENING SPACE",NSRect(x:58,y:46,width:500,height:28),15,color(0.94,0.87,0.70),.medium)
            return true
        }
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        if CommandLine.arguments.contains("--render-previews") {renderPreviews();NSApp.terminate(nil);return}
        if CommandLine.arguments.contains("--export-demo"){exportDemo();NSApp.terminate(nil);return}
        if CommandLine.arguments.contains("--verify-collection"){verifyCollection();NSApp.terminate(nil);return}
        if CommandLine.arguments.contains("--verify-skips"){verifyAsyncSkips();NSApp.terminate(nil);return}
        NSApp.setActivationPolicy(.accessory)
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);status.button?.image=NSImage(systemSymbolName:"opticaldisc",accessibilityDescription:"Record Room");status.button?.target=self;status.button?.action = #selector(togglePanel)
        makePanel();makeDesktops();showPanel();if enabled{poll()}
        if !prefs.bool(forKey:"setupCompleted"){DispatchQueue.main.async{[weak self] in self?.showSetup()}}
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(wake),name:NSWorkspace.didWakeNotification,object:nil)
        let workspace=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification]{
            workspace.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.renderingSuspended=true;self?.updateRenderingPolicies()}
        }
        for name in [NSWorkspace.screensDidWakeNotification,NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification]{
            workspace.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.renderingSuspended=false;self?.updateRenderingPolicies()}
        }
        pollTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true){[weak self] _ in self?.poll()}
        animationTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in self?.updateTimeDisplay()}
    }
    func makeDesktops() {
        desktopWindows.forEach{$0.orderOut(nil)};desktopWindows=[];desktopViews=[]
        for screen in NSScreen.screens { let win=NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false,screen:screen);win.setFrame(screen.frame,display:false);win.level=NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopWindow))+1);win.collectionBehavior=[.canJoinAllSpaces,.stationary,.ignoresCycle];win.ignoresMouseEvents=true;win.isReleasedWhenClosed=false
            let view=RoomView(frame:NSRect(origin:.zero,size:screen.frame.size));win.contentView=view;desktopWindows.append(win);desktopViews.append(view)
        };refresh()
    }
    @objc func screenChanged(){makeDesktops()}
    @objc func wake(){poll()}
    func button(_ text:String,_ action:Selector,_ frame:NSRect) -> NSButton {let b=NSButton(title:text,target:self,action:action);b.frame=frame;b.bezelStyle = .rounded;panel.contentView?.addSubview(b);return b}
    func text(_ value:String,_ frame:NSRect,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular) -> NSTextField {let t=NSTextField(labelWithString:value);t.frame=frame;t.font = .systemFont(ofSize:size,weight:weight);t.lineBreakMode = .byTruncatingTail;panel.contentView?.addSubview(t);return t}
    func makePanel(){
        panel=NSPanel(contentRect:NSRect(x:0,y:0,width:480,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false);panel.title="Record Room";panel.animationBehavior = .utilityWindow;panel.isReleasedWhenClosed=false;panel.level = .floating
        preview=RoomView(frame:NSRect(x:20,y:370,width:440,height:248));preview.setAccessibilityElement(true);preview.setAccessibilityLabel("Record player and session collection. Use Browse to inspect an album.");preview.wantsLayer=true;preview.layer?.cornerRadius=10;preview.layer?.masksToBounds=true;preview.onSelect = {[weak self] key in self?.showAlbum(key)};panel.contentView?.addSubview(preview)
        titleField=text("Your listening room",NSRect(x:24,y:332,width:430,height:26),19,.semibold)
        artistField=text("Connect a player to bring your albums into the room.",NSRect(x:24,y:308,width:430,height:22),12);artistField.textColor = .secondaryLabelColor
        progress=NSProgressIndicator(frame:NSRect(x:24,y:290,width:432,height:5));progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;panel.contentView?.addSubview(progress)
        timeField=text("0:00 / 0:00",NSRect(x:24,y:266,width:432,height:18),11);timeField.textColor = .secondaryLabelColor
        let scenes=NSSegmentedControl(labels:["Studio","After Hours","Overhead"],trackingMode:.selectOne,target:self,action:#selector(changeScene(_:)));scenes.frame=NSRect(x:24,y:223,width:432,height:30);scenes.selectedSegment=scene;panel.contentView?.addSubview(scenes)
        sessionField=text("Session crate · 0 albums",NSRect(x:24,y:192,width:220,height:22),12,.medium)
        _=button("Browse",#selector(browseSession),NSRect(x:254,y:189,width:85,height:28))
        _=button("New session",#selector(clearStack),NSRect(x:348,y:189,width:108,height:28))
        let hide=NSButton(checkboxWithTitle:"Hide desktop scene when paused",target:self,action:#selector(toggleHide(_:)));hide.frame=NSRect(x:24,y:158,width:420,height:22);hide.state=hidePaused ? .on:.off;panel.contentView?.addSubview(hide)
        let login=NSButton(checkboxWithTitle:"Launch at login",target:self,action:#selector(toggleLogin(_:)));login.frame=NSRect(x:24,y:130,width:420,height:22);login.state=SMAppService.mainApp.status == .enabled ? .on:.off;panel.contentView?.addSubview(login)
        stateField=text("Music access is off. Your original wallpaper is underneath.",NSRect(x:24,y:94,width:432,height:26),11);stateField.textColor = .secondaryLabelColor
        _=button("Connect music",#selector(connectMusic),NSRect(x:20,y:48,width:145,height:32))
        _=button("Show / hide room",#selector(toggleRoom),NSRect(x:171,y:48,width:160,height:32))
        _=button("Quit",#selector(quit),NSRect(x:365,y:48,width:95,height:32))
        _=button("Help & feedback",#selector(helpMenu(_:)),NSRect(x:24,y:12,width:145,height:26))
    }
    @objc func showSetup(){
        let alert=NSAlert();alert.messageText="Welcome to Record Room"
        alert.informativeText="1. Open Apple Music or Spotify and play an album.\n\n2. Choose Connect music and allow Automation access when macOS asks.\n\n3. Albums collect in your session crate. Open Browse to inspect a pressing.\n\nFind Record Room using the disc icon in your menu bar. Room preferences are remembered; the collection lasts for this app session. System Reduce Motion is respected."
        alert.addButton(withTitle:"Connect music");alert.addButton(withTitle:"Later")
        let result=alert.runModal();prefs.set(true,forKey:"setupCompleted")
        if result == .alertFirstButtonReturn{connectMusic()}
    }
    @objc func helpMenu(_ sender:NSButton){
        let menu=NSMenu()
        for (title,action) in [("Getting started",#selector(showSetup)),("Privacy",#selector(showPrivacy)),("Export bug report…",#selector(exportDiagnostics))]{let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)}
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.minY),in:sender)
    }
    @objc func showPrivacy(){
        let alert=NSAlert();alert.messageText="Your listening room stays on this Mac"
        alert.informativeText="Record Room reads your current song, playback state and artwork from Apple Music or Spotify. Spotify artwork is fetched directly from the artwork URL provided by Spotify.\n\nYour session collection stays in memory. Preferences are stored on this Mac. There is no Record Room account, advertising, tracking or analytics service.\n\nBug reports are saved only when you choose Export bug report. They exclude song titles, artists and artwork. You decide where to send them. Revoke Automation access in System Settings → Privacy & Security → Automation."
        alert.runModal()
    }
    @objc func exportDiagnostics(){
        let save=NSSavePanel();save.nameFieldStringValue="Record-Room-bug-report.txt"
        guard save.runModal() == .OK,let url=save.url else{return}
        let info=Bundle.main.infoDictionary ?? [:]
        let report="""
        Record Room beta report
        Version: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        System: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Screens: \(NSScreen.screens.count)
        Playing: \(playing)
        Scene visible: \(active)
        Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        Session album count: \(albums.count)
        Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)

        What happened?

        Steps to reproduce:

        Expected behavior:

        Song titles, artist names, artwork and listening history are excluded.
        """
        do{try report.write(to:url,atomically:true,encoding:.utf8)}catch{let alert=NSAlert(error:error);alert.runModal()}
    }
    @objc func togglePanel(){if panel.isVisible{panel.orderOut(nil)}else{showPanel()};updateRenderingPolicies()}
    func showPanel(){panel.center();panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);updateRenderingPolicies()}
    @objc func connectMusic(){enabled=true;prefs.set(true,forKey:"musicEnabled");stateField.stringValue="Open Spotify or Music and play a track. Allow music access when asked.";poll()}
    @objc func toggleRoom(){active.toggle();prefs.set(active,forKey:"roomVisible");refresh()}
    @objc func quit(){NSApp.terminate(nil)}
    @objc func clearStack(){
        let alert=NSAlert();alert.messageText="Start a new session?";alert.informativeText="The current album stays. Earlier albums are removed from the collection.";alert.addButton(withTitle:"Start new session");alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn{albums=albums.filter{$0.key==currentKey};refresh()}
    }
    @objc func changeScene(_ sender:NSSegmentedControl){scene=sender.selectedSegment;prefs.set(scene,forKey:"scene");refresh()}
    @objc func toggleHide(_ sender:NSButton){hidePaused=sender.state == .on;prefs.set(hidePaused,forKey:"hidePaused");refresh()}
    @objc func toggleLogin(_ sender:NSButton){do{if sender.state == .on{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}}catch{sender.state=SMAppService.mainApp.status == .enabled ? .on:.off;stateField.stringValue="Login setting: \(error.localizedDescription)"}}
    func refresh(){
        ([preview].compactMap{$0}+desktopViews).forEach{$0.sceneStyle=scene;$0.currentKey=currentKey;$0.album=currentArt ?? (currentKey.isEmpty ? placeholder:nil);$0.stack=albums;$0.playbackDuration=duration;$0.updatePlayback(playing:playing,fraction:CGFloat(displayPosition/duration),track:currentTrackIdentity)}
        sessionField?.stringValue="Session crate · \(albums.count) album\(albums.count == 1 ? "":"s")"
        for win in desktopWindows{if active && !(hidePaused && !playing){if !win.isVisible{win.orderFrontRegardless()}}else{win.orderOut(nil)}}
        gallery?.update(albums)
        updateRenderingPolicies()
    }
    func updateRenderingPolicies(){
        for view in [preview].compactMap({$0})+desktopViews {
            let visible=view.window.map{$0.isVisible && $0.occlusionState.contains(.visible)} ?? false
            view.setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            view.updateRenderingPolicy(visible:visible && !renderingSuspended)
        }
    }
    var displayPosition:Double{min(duration,max(0,position+(playing ? Date().timeIntervalSince(positionSampledAt):0)))}
    func updateTimeDisplay(){
        updateRenderingPolicies()
        guard timeField != nil else{return}
        let elapsed=displayPosition,remaining=max(0,duration-elapsed)
        func stamp(_ n:Double)->String{String(format:"%d:%02d",Int(n)/60,Int(n)%60)}
        timeField.stringValue="\(stamp(elapsed)) / \(stamp(duration))  ·  −\(stamp(ceil(remaining))) left  ·  \(playing ? "Playing":"Paused")"
        progress.doubleValue=elapsed/max(1,duration)
    }
    func runScript(_ source:String) -> (NSAppleEventDescriptor?,String?){var error:NSDictionary?;let result=NSAppleScript(source:source)?.executeAndReturnError(&error);return(result,error?[NSAppleScript.errorMessage] as? String)}
    func poll(){
        guard enabled && !pollBusy else{return};pollBusy=true
        let running=NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let candidates=[("com.spotify.client","Spotify"),("com.apple.Music","Music")].filter{running.contains($0.0)}
        guard !candidates.isEmpty else{pollBusy=false;playing=false;stateField.stringValue="Open Spotify or Music, then play an album.";refresh();return}
        musicQueue.async{[weak self] in
            guard let self=self else{return};var chosen:(String,[String])?;var problem:String?
            for (id,name) in candidates {
                let spotify=id=="com.spotify.client"
                let script="""
                tell application id "\(id)"
                    if not (exists current track) then return {}
                    set t to current track
                    return {player state as string, name of t as string, artist of t as string, album of t as string, \(spotify ? "(duration of t) / 1000" : "duration of t"), player position, \(spotify ? "artwork url of t as string" : "persistent ID of t as string")}
                end tell
                """
                let (descriptor,error)=self.runScript(script);if let error=error{problem=error;continue}
                guard let d=descriptor,d.numberOfItems>=7 else{continue};let values=(1...7).map{d.atIndex($0)?.stringValue ?? ""}
                if chosen==nil || values[0]=="playing"{chosen=(name,values)};if values[0]=="playing"{break}
            }
            DispatchQueue.main.async{self.pollBusy=false
                guard let (name,v)=chosen else{self.playing=false;self.stateField.stringValue=problem.map{"Music access: \($0)"} ?? "No current track. Play a song to begin.";self.refresh();return}
                self.source=name;self.playing=v[0]=="playing";let sampledDuration=Double(v[4]) ?? 1,sampledPosition=Double(v[5]) ?? 0;self.duration=sampledDuration.isFinite ? max(1,sampledDuration):1;self.position=sampledPosition.isFinite ? max(0,sampledPosition):0;self.positionSampledAt=Date();self.currentTrackIdentity="\(name)|\(v[1])|\(v[2])|\(v[4])"
                self.titleField.stringValue=v[1];self.artistField.stringValue="\(v[2]) · \(v[3])";self.progress.doubleValue=min(1,self.position/self.duration)
                self.updateTimeDisplay()
                self.stateField.stringValue="Connected to \(name) · desktop stays beneath your icons."
                let key="\(v[2])|\(v[3])"
                if self.playing && key != self.currentKey {self.artworkAttempts=0;self.missingArtworkKey=nil;self.currentKey=key;self.currentArt=nil;self.loadArtwork(player:name,reference:v[6],key:key,title:v[3],artist:v[2])}
                if self.missingArtworkKey==key,self.artworkAttempts<3,Date()>=self.artworkRetryAt{self.loadArtwork(player:name,reference:v[6],key:key,title:v[3],artist:v[2])}
                self.refresh()
            }
        }
    }
    func loadArtwork(player:String,reference:String,key:String,title:String,artist:String){
        artTask?.cancel();artworkAttempts+=1;artworkRetryAt=Date(timeIntervalSinceNow:10)
        if missingArtworkKey != key,let old=albums.first(where:{$0.key==key}){currentArt=old.art;refresh();return}
        if player=="Spotify",let url=URL(string:reference),url.scheme=="https"{
            artTask=URLSession.shared.dataTask(with:url){[weak self] data,_,_ in DispatchQueue.main.async{guard let s=self,s.currentKey==key else{return};s.acceptArt(data.flatMap{NSImage(data:$0)},key:key,title:title,artist:artist)}};artTask?.resume()
        }else if player=="Music"{
            // Music exposes artwork as native Apple event image data, without a network lookup.
            musicQueue.async{[weak self] in guard let s=self else{return};let (d,_)=s.runScript("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track");let image=d.flatMap{NSImage(data:$0.data)};DispatchQueue.main.async{guard s.currentKey==key else{return};s.acceptArt(image,key:key,title:title,artist:artist)}}
        }else{acceptArt(nil,key:key,title:title,artist:artist)}
    }
    func acceptArt(_ image:NSImage?,key:String,title:String,artist:String){let art=image ?? placeholder;currentArt=art
        missingArtworkKey=image==nil ? key:nil
        if image != nil{RoomView.pressingCache.removeObject(forKey:key as NSString)}
        if let i=albums.firstIndex(where:{$0.key==key}){albums[i].art=art}
        if !albums.contains(where:{$0.key==key}){albums.append(Album(key:key,title:title,artist:artist,art:art))};refresh()
    }
    @objc func browseSession(_ sender:NSButton){
        if gallery==nil{
            gallery=SessionGallery();gallery?.onInspect={[weak self] key in self?.showAlbum(key)};gallery?.onExport={[weak self] in self?.exportSessionImage()}
        }
        gallery?.update(albums);gallery?.panel.center();gallery?.panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func sessionPoster(_ values:[Album])->NSImage{
        let shown=Array(values.suffix(24)),rows=max(1,(shown.count+2)/3),height=300+rows*370
        return NSImage(size:NSSize(width:1200,height:height),flipped:true){r in
            fill(r,color(0.95,0.94,0.90));label("RECORD ROOM / THIS LISTENING SESSION",NSRect(x:58,y:44,width:1080,height:30),18,color(0.27,0.30,0.29),.medium)
            label("A little collection of today.",NSRect(x:58,y:94,width:1080,height:64),45,color(0.09,0.15,0.14),.semibold)
            let date=values.first?.listenedAt ?? Date();let df=DateFormatter();df.dateStyle = .medium
            label("\(values.count) albums · \(df.string(from:date))",NSRect(x:58,y:176,width:1080,height:32),21,color(0.40,0.42,0.39))
            for (i,album) in shown.enumerated(){
                let x=CGFloat(58+(i%3)*370),y=CGFloat(240+(i/3)*370)
                fill(NSRect(x:x+3,y:y+5,width:316,height:316),color(0.09,0.15,0.14,0.12));album.art.draw(in:NSRect(x:x,y:y,width:316,height:316))
                let style=NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
                (album.title as NSString).draw(in:NSRect(x:x,y:y+325,width:316,height:25),withAttributes:[.font:NSFont.systemFont(ofSize:17,weight:.semibold),.foregroundColor:color(0.09,0.15,0.14),.paragraphStyle:style])
                (album.artist as NSString).draw(in:NSRect(x:x,y:y+351,width:316,height:20),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:color(0.40,0.42,0.39),.paragraphStyle:style])
            }
            label(values.count>24 ? "Latest 24 shown · made in Record Room":"Made in Record Room · free to enjoy",NSRect(x:58,y:CGFloat(height-38),width:1080,height:24),14,color(0.40,0.42,0.39));return true
        }
    }
    @objc func exportSessionImage(){
        guard !albums.isEmpty else{return}
        let save=NSSavePanel();save.nameFieldStringValue="Record-Room-Session.png"
        guard save.runModal() == .OK,let url=save.url else{return}
        let image=sessionPoster(albums)
        do{guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{return};try png.write(to:url,options:.atomic)}catch{NSAlert(error:error).runModal()}
    }
    @objc func selectedAlbum(_ sender:NSMenuItem){if let key=sender.representedObject as? String{showAlbum(key)}}
    func showAlbum(_ key:String){
        guard let album=albums.first(where:{$0.key==key})else{return}
        inspection?.close()
        let sheet=NSPanel(contentRect:NSRect(x:0,y:0,width:780,height:610),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        sheet.title="Your collection";sheet.animationBehavior = .utilityWindow;sheet.isReleasedWhenClosed=false;sheet.minSize=NSSize(width:640,height:520)
        let room=RoomView(frame:NSRect(x:0,y:140,width:780,height:470));room.autoresizingMask=[.width,.height]
        room.currentKey=album.key;room.album=album.art;room.configureInspection();sheet.contentView?.addSubview(room)
        func caption(_ value:String,y:CGFloat,size:CGFloat,weight:NSFont.Weight = .regular){
            let field=NSTextField(labelWithString:value);field.frame=NSRect(x:28,y:y,width:724,height:26)
            field.font = .systemFont(ofSize:size,weight:weight);field.lineBreakMode = .byTruncatingTail;field.autoresizingMask=[.width]
            sheet.contentView?.addSubview(field)
        }
        caption(album.title,y:102,size:21,weight:.semibold);caption(album.artist,y:76,size:14)
        let df=DateFormatter();df.timeStyle = .short
        caption("\(room.variant(for:album.art,key:album.key).name)  ·  First played at \(df.string(from:album.listenedAt))",y:44,size:12)
        caption("Drag to explore your pressing · Scroll to zoom",y:12,size:11)
        inspection=sheet;sheet.center();sheet.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func demoArtwork(_ index:Int)->NSImage{
        NSImage(size:NSSize(width:800,height:800),flipped:false){r in
            let palettes=[(color(0.77,0.33,0.18),color(0.96,0.83,0.58)),(color(0.10,0.27,0.30),color(0.63,0.77,0.74)),(color(0.72,0.70,0.57),color(0.22,0.29,0.24))]
            let colors=palettes[index%3];fill(r,colors.0)
            if index%3==0{for i in 0..<7{let v=CGFloat(i);oval(NSRect(x:90+v*28,y:90+v*28,width:620-v*56,height:620-v*56),colors.1.withAlphaComponent(0.10+v*0.04))}}
            else if index%3==1{for i in 0..<8{fill(NSRect(x:CGFloat(i)*100,y:160,width:48,height:480),colors.1.withAlphaComponent(0.5))}}
            else{oval(NSRect(x:100,y:200,width:600,height:380),colors.1);fill(NSRect(x:100,y:200,width:300,height:380),colors.0)}
            label(["WARM FREQUENCIES","BLUE HOUR","SOFT GEOMETRY"][index%3],NSRect(x:48,y:690,width:710,height:60),38,colors.1,.semibold)
            label("RECORD ROOM / DEMO ARTWORK",NSRect(x:48,y:46,width:710,height:30),18,colors.1,.medium);return true
        }
    }
    func verifyCollection(){
        let demos=(0..<30).map{Album(key:"demo-\($0)",title:"Demo album \($0)",artist:"Record Room",art:demoArtwork($0))}
        let gallery=SessionGallery();gallery.update(demos);gallery.panel.contentView?.layoutSubtreeIfNeeded();gallery.grid.layoutSubtreeIfNeeded()
        precondition(gallery.grid.frame.width>700 && gallery.grid.numberOfItems(inSection:0)==30)
        let poster=sessionPoster(demos);precondition(poster.size==NSSize(width:1200,height:3260))
        let bitmap=NSBitmapImageRep(data:poster.tiffRepresentation!)!;precondition(bitmap.pixelsWide>=1200)
        let output=URL(fileURLWithPath:CommandLine.arguments.last!);try! bitmap.representation(using:.png,properties:[:])!.write(to:output)
        print("PASS: 30-album gallery, nonzero layout, bounded 24-cover poster and PNG export")
    }
    func exportDemo(){
        let output=URL(fileURLWithPath:CommandLine.arguments.last!);try? FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        let names=["Warm Frequencies","Blue Hour","Soft Geometry"]
        let demos=(0..<3).map{Album(key:"record-room-demo-\($0)",title:names[$0],artist:"Record Room demo",art:demoArtwork($0))}
        let room=RoomView(frame:NSRect(x:0,y:0,width:1280,height:800));let window=NSWindow(contentRect:room.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=room
        room.currentKey=demos[0].key;room.album=demos[0].art;room.stack=[demos[0]];room.updatePlayback(playing:true,fraction:0,track:"demo-track-a");room.isPlaying=false
        let renderer=SCNRenderer(device:MTLCreateSystemDefaultDevice(),options:nil);renderer.scene=room.world;renderer.pointOfView=room.cameraNode;renderer.autoenablesDefaultLighting=false
        let writer=try! AVAssetWriter(outputURL:output,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1280,AVVideoHeightKey:800,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:2_800_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:1280,kCVPixelBufferHeightKey as String:800,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        writer.add(input);precondition(writer.startWriting());writer.startSession(atSourceTime:.zero)
        for frame in 0..<450{
            autoreleasepool{
                if frame==150 || frame==300{let index=frame/150;room.currentKey=demos[index].key;room.album=demos[index].art;room.stack=Array(demos.prefix(index+1));room.updatePlayback(playing:true,fraction:0,track:"demo-track-\(index)")}
                RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))
                let image=renderer.snapshot(atTime:Double(frame)/30,with:CGSize(width:1280,height:800),antialiasingMode:.multisampling4X)
                let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
                while !input.isReadyForMoreMediaData{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.001))}
                var buffer:CVPixelBuffer?;precondition(CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)==kCVReturnSuccess)
                CVPixelBufferLockBaseAddress(buffer!,[])
                let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer!),width:1280,height:800,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer!),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue)!
                context.draw(cg,in:CGRect(x:0,y:0,width:1280,height:800));CVPixelBufferUnlockBaseAddress(buffer!,[])
                precondition(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
                if frame==120{let bitmap=NSBitmapImageRep(cgImage:cg);try! bitmap.representation(using:.png,properties:[:])!.write(to:output.deletingLastPathComponent().appendingPathComponent("room-poster.png"))}
            }
        }
        input.markAsFinished();var finished=false;writer.finishWriting{finished=true}
        while !finished{RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01))}
        precondition(writer.status == .completed,writer.error?.localizedDescription ?? "Video export failed")
        let poster=sessionPoster(demos);let data=NSBitmapImageRep(data:poster.tiffRepresentation!)!.representation(using:.png,properties:[:])!;try! data.write(to:output.deletingLastPathComponent().appendingPathComponent("session-poster.png"))
        window.orderOut(nil);print("Exported actual app renderer, 15 seconds / 450 frames / demo artwork only")
    }

    func verifyAsyncSkips(){
        let v=RoomView(frame:NSRect(x:0,y:0,width:640,height:400))
        let w=NSWindow(contentRect:v.frame,styleMask:.borderless,backing:.buffered,defer:false);w.contentView=v;w.orderFrontRegardless()
        let art=placeholder
        func waitFor(_ key:String){
            let deadline=Date(timeIntervalSinceNow:12)
            while Date()<deadline && (v.lastArtworkKey != key || v.exchanging || v.preparingKey != nil){RunLoop.current.run(until:Date(timeIntervalSinceNow:0.02))}
            precondition(v.lastArtworkKey==key && !v.exchanging && v.preparingKey==nil,"Async latest skip failed to settle")
        }
        v.currentKey="async-initial";v.album=art;waitFor(v.currentKey)
        for i in 0..<12{v.currentKey="async-skip-\(i)";v.album=art}
        waitFor("async-skip-11")
        precondition(v.readyPressing?.key=="async-skip-11" && v.gpuReadyKey=="async-skip-11","Stale texture won the GPU preparation race")
        precondition(v.readyPressing!.value.texture.width==1600 && v.readyPressing!.value.texture.bitsPerComponent==8)
        let sample=v.snapshot();let pixels=sample.cgImage(forProposedRect:nil,context:nil,hints:nil)!
        print("Display scale",w.backingScaleFactor,"layer scale",v.layer?.contentsScale ?? 0,"snapshot pixels",pixels.width,pixels.height)
        w.orderOut(nil);print("PASS: real async generation, cancellation, GPU prewarming and latest of 12 rapid skips")
    }

    func renderPreviews(){
        let out=CommandLine.arguments.last!;try? FileManager.default.createDirectory(atPath:out,withIntermediateDirectories:true)
        let view=RoomView(frame:NSRect(x:0,y:0,width:3200,height:1800));view.album=placeholder;view.stack=(0..<6).map{Album(key:"\($0)",title:"Demo",artist:"Demo",art:placeholder)}
        let expected:[VinylVariant.Style]=[.black,.twotone,.marble,.splatter,.translucent]
        for style in expected {
            let key=(0..<2000).map{"preview-album-\($0)"}.first{view.variant(for:placeholder,key:$0).style == style}!
            view.currentKey=key;view.album=placeholder;view.sceneStyle=0;SCNTransaction.flush()
            let img=view.snapshot();if let data=img.tiffRepresentation,let rep=NSBitmapImageRep(data:data){try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:out+"/pressing-\(style).png"))}
        }
        for i in 0..<3{view.sceneStyle=i;SCNTransaction.flush();let image=view.snapshot();if let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data){try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:out+"/scene-\(i).png"))}}

        view.sceneStyle=0
        view.cameraNode.position=SCNVector3(2.8,4.6,6.5);view.cameraNode.look(at:SCNVector3(-0.35,0.5,0))
        view.cameraNode.camera?.orthographicScale=2.6
        SCNTransaction.flush()
        if let data=view.snapshot().tiffRepresentation,let rep=NSBitmapImageRep(data:data){try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:out+"/turntable-detail.png"))}
        let closeup=RoomView(frame:NSRect(x:0,y:0,width:2400,height:1500))
        let marbleKey=(0..<2000).map{"preview-album-\($0)"}.first{closeup.variant(for:placeholder,key:$0).style == .marble}!
        closeup.currentKey=marbleKey;closeup.album=placeholder;closeup.configureInspection();SCNTransaction.flush()
        if let data=closeup.snapshot().tiffRepresentation,let rep=NSBitmapImageRep(data:data){try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:out+"/inspection.png"))}
        // Regression: waiting for cover art must not cache a temporary pressing.
        let waiting=RoomView(frame:NSRect(x:0,y:0,width:400,height:225));waiting.currentKey="waiting-for-cover";waiting.album=nil
        precondition(RoomView.pressingCache.object(forKey:"waiting-for-cover")==nil)
        let motion=RoomView(frame:NSRect(x:0,y:0,width:400,height:225));motion.playbackDuration=240;let testWindow=NSWindow(contentRect:motion.frame,styleMask:.borderless,backing:.buffered,defer:false);testWindow.contentView=motion;testWindow.orderFrontRegardless();_ = motion.snapshot()
        func advance(){for _ in 0..<42{RunLoop.current.run(until:Date(timeIntervalSinceNow:1.0/30));_ = motion.snapshot();let joint=motion.tonearmLift.presentation.position;precondition(abs(joint.x)+abs(joint.y)+abs(joint.z)<0.0001,"Tonearm detached from gimbal")}}
        motion.updatePlayback(playing:true,fraction:0,track:"test-a");advance()
        print("Playing arm angle:",motion.tonearmPivot.presentation.eulerAngles.y);fflush(stdout)
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y+0.08)<0.025,"Arm failed to reach record")
        motion.updatePlayback(playing:false,fraction:0,track:"test-a");advance()
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y-0.47)<0.025,"Arm failed to park")
        motion.updatePlayback(playing:true,fraction:0,track:"test-a");motion.updatePlayback(playing:false,fraction:0,track:"test-a");motion.updatePlayback(playing:true,fraction:0,track:"test-a");advance()
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y+0.08)<0.025,"Rapid play/pause failed")
        motion.updatePlayback(playing:true,fraction:0.75,track:"test-a");advance()
        precondition(motion.tonearmPivot.presentation.eulerAngles.y < -0.20,"Arm did not follow song progress")
        motion.updatePlayback(playing:true,fraction:0,track:"test-b");advance()
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y+0.08)<0.025,"Next song did not reset arm")
        motion.updatePlayback(playing:false,fraction:0,track:"test-b");advance()
        for (i,cone) in motion.speakerCones.enumerated(){precondition(abs(cone.presentation.position.z-motion.coneRestDepth[i])<0.001,"Speaker failed to settle")}
        let old=Album(key:"departing",title:"Departing",artist:"Test",art:placeholder)
        motion.currentKey=old.key;motion.album=old.art;motion.stack=[old]
        motion.currentKey="arriving"
        motion.album=placeholder
        motion.stack=[old,Album(key:"arriving",title:"Arriving",artist:"Test",art:placeholder)]
        precondition(motion.exchanging,"Album change did not start exchange")
        motion.updatePlayback(playing:true,fraction:0,track:"arriving-track")
        advance()
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y-0.47)<0.025,"Arm must park before exchanging records")
        precondition(motion.crateRecords.childNodes.count==1)
        advance();advance()
        precondition(!motion.exchanging && motion.lastArtworkKey=="arriving")
        precondition(abs(motion.record.position.y-0.72)<0.001 && motion.record.opacity==1)
        // A fast second album selection and pause must win over an in-flight exchange.
        motion.currentKey="skip-a";motion.album=placeholder
        motion.currentKey="skip-b";motion.album=placeholder
        motion.updatePlayback(playing:false,fraction:0,track:"skip-b-track")
        advance();advance();advance()
        precondition(!motion.exchanging && motion.lastArtworkKey=="skip-b","Stale album won rapid skip")
        precondition(abs(motion.tonearmPivot.presentation.eulerAngles.y-0.47)<0.025)
        precondition(abs(motion.recordAngularVelocity)<0.001,"Paused exchange restarted platter")
        motion.album=placeholder
        precondition(!motion.exchanging,"Same album triggered another exchange")
        motion.exchanging=true;motion.exchangeStarted=Date(timeIntervalSinceNow:-7)
        motion.recoverMotionIfNeeded();advance()
        precondition(!motion.exchanging && motion.record.opacity==1,"Exchange recovery failed")
        motion.armTransitioning=true;motion.armStarted=Date(timeIntervalSinceNow:-3)
        motion.tonearmLift.eulerAngles.x = -0.08;motion.recoverMotionIfNeeded()
        precondition(!motion.armTransitioning && motion.tonearmLift.eulerAngles.x==0,"Needle recovery failed")
        let crateTest=RoomView(frame:NSRect(x:0,y:0,width:400,height:225))
        crateTest.stack=(0..<20).map{Album(key:"bound-\($0)",title:"Test",artist:"Test",art:placeholder)}
        precondition(crateTest.crateRecords.childNodes.count==14)
        let retained=crateTest.crateRecords.childNodes[0];crateTest.updateCrate(force:true)
        precondition(crateTest.crateRecords.childNodes[0] === retained,"Crate refresh rebuilt sleeves")
        for node in crateTest.crateRecords.childNodes {
            for x:CGFloat in [-0.95,0.95] {for y:CGFloat in [-0.95,0.95] {for z:CGFloat in [-0.0125,0.0125] {
                let point=node.convertPosition(SCNVector3(x,y,z),to:crateTest.crateRecords)
                precondition(point.x>2.25 && point.x<4.25 && point.z > -0.775 && point.z < 1.175 && point.y > 0.135,"Sleeve clips crate")
            }}}
        }
        // Sample the entire flight, including the crate rim and turntable clearance.
        let flight=SCNNode();crateTest.world.rootNode.addChildNode(flight)
        for index in 0..<14 {for frame in 0...200 {
            let pose=crateTest.filingPose(from:crateTest.sleeve.position,angles:crateTest.sleeve.eulerAngles,to:SCNVector3(3.25,1.10,-0.65+Double(index)*0.12),fraction:CGFloat(frame)/200)
            flight.position=pose.0;flight.eulerAngles=pose.1
            var corners:[SCNVector3]=[]
            for x:CGFloat in [-0.95,0.95] {for y:CGFloat in [-0.95,0.95] {for z:CGFloat in [-0.0125,0.0125] {corners.append(flight.convertPosition(SCNVector3(x,y,z),to:nil))}}}
            let minX=corners.map(\.x).min()!,maxX=corners.map(\.x).max()!,minY=corners.map(\.y).min()!
            if maxX > -2.375 && minX < 1.675 {precondition(minY>0.62,"Filing sleeve clips turntable")}
            if maxX > 2.16 && minX < 2.25 {precondition(minY>0.90,"Filing sleeve clips crate rim")}
        }}
        flight.removeFromParentNode()
        motion.updateRenderingPolicy(visible:true)
        precondition(!motion.isPlaying,"Paused scene must stop rendering")
        motion.playbackActive=true;motion.updateRenderingPolicy(visible:true)
        precondition(motion.isPlaying && motion.preferredFramesPerSecond==30,"Steady playback must use 30 fps")
        motion.armTransitioning=true;motion.updateRenderingPolicy(visible:true)
        precondition(motion.preferredFramesPerSecond==60,"Transitions must retain 60 fps")
        motion.updateRenderingPolicy(visible:false)
        precondition(!motion.isPlaying,"Hidden scene must stop rendering")
        motion.setReducedMotion(true)
        precondition(!motion.exchanging && motion.recordAngularVelocity==0 && motion.tonearmLift.eulerAngles.x==0,"Reduce Motion must settle the scene")
        motion.updateRenderingPolicy(visible:true);precondition(!motion.isPlaying,"Reduce Motion must not keep decorative frames running")
        let held=motion.readyPressing!
        precondition(held.value.texture.width==1600 && held.value.texture.bitsPerComponent==8,"Vinyl texture expanded with Retina scale")
        precondition(held.value.label.width==512 && held.value.cover.width==1024,"Artwork texture budget changed")
        RoomView.pressingCache.removeAllObjects()
        motion.applyArtwork(placeholder,key:held.key)
        precondition(motion.readyPressing?.value === held.value,"Cache eviction discarded the active pressing")
        print("Verified stable crate nodes and full 14-sleeve crate clearance.")
        testWindow.orderOut(nil)
        print("Verified pressings, attached hinge, play/pause, interruptions, song progress, next-track reset, speaker settling, record exchange, rapid album skips, and pause during exchange.")

    }
}
let app=NSApplication.shared
let delegate=AppDelegate();app.delegate=delegate;app.run()
