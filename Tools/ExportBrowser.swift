let app=NSApplication.shared
let output=URL(fileURLWithPath:CommandLine.arguments.last!)
try! FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let room=RoomView(frame:NSRect(x:0,y:0,width:1440,height:900))
room.isPlaying=false
room.record.name="record";room.sleeve.name="sleeve";room.crateRecords.name="crateRecords";room.tonearmPivot.name="armPivot";room.tonearmLift.name="armLift";room.cameraNode.name="camera"
for (i,n) in room.speakerCones.enumerated(){n.name="cone-\(i)"}
room.sleeveFace.name="cover";room.discSurface.name="vinyl";room.discLabel.name="label";room.discEdge.name="edge";room.powerLens.name="power"
func rgba(_ value:Any?)->[Double]?{guard let c=(value as? NSColor)?.usingColorSpace(.sRGB) else{return nil};return [Double(c.redComponent),Double(c.greenComponent),Double(c.blueComponent),Double(c.alphaComponent)]}
var textures:[ObjectIdentifier:String]=[:],materials:[[String:Any]]=[],materialIDs:[ObjectIdentifier:Int]=[:]
func imageFile(_ value:Any?)->String?{
    guard let value=value else{return nil}
    var cg:CGImage?
    if let image=value as? NSImage{cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)}else if CFGetTypeID(value as CFTypeRef)==CGImage.typeID{cg=(value as! CGImage)}
    guard let image=cg else{return nil};let id=ObjectIdentifier(image)
    if let existing=textures[id]{return existing}
    let name="texture-\(textures.count).png";textures[id]=name
    let bitmap=NSBitmapImageRep(cgImage:image);try! bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name));return name
}
func property(_ p:SCNMaterialProperty)->[String:Any]{
    var result:[String:Any]=["intensity":p.intensity,"transform":matrix(p.contentsTransform),"repeatS":p.wrapS == .repeat,"repeatT":p.wrapT == .repeat]
    if let c=rgba(p.contents){result["color"]=c}else if let n=p.contents as? NSNumber{result["scalar"]=n.doubleValue}else if let file=imageFile(p.contents){result["texture"]=file};return result
}
func matrix(_ m:SCNMatrix4)->[Float]{[m.m11,m.m12,m.m13,m.m14,m.m21,m.m22,m.m23,m.m24,m.m31,m.m32,m.m33,m.m34,m.m41,m.m42,m.m43,m.m44].map{Float($0)}}
func mat(_ m:SCNMaterial)->Int{
    let id=ObjectIdentifier(m);if let i=materialIDs[id]{return i};let i=materials.count;materialIDs[id]=i
    materials.append(["name":m.name ?? "","diffuse":property(m.diffuse),"roughness":property(m.roughness),"metalness":property(m.metalness),"emission":property(m.emission),"doubleSided":m.isDoubleSided,"opacity":m.transparency]);return i
}
func values(_ s:SCNGeometrySource)->[Float]{
    precondition(s.usesFloatComponents && [4,8].contains(s.bytesPerComponent),"Unsupported attribute")
    var result:[Float]=[];result.reserveCapacity(s.vectorCount*s.componentsPerVector)
    s.data.withUnsafeBytes{data in for i in 0..<s.vectorCount{for j in 0..<s.componentsPerVector{let offset=s.dataOffset+i*s.dataStride+j*s.bytesPerComponent;result.append(s.bytesPerComponent==4 ? data.loadUnaligned(fromByteOffset:offset,as:Float.self):Float(data.loadUnaligned(fromByteOffset:offset,as:Double.self)))}}};return result
}
func encoded<T>(_ list:[T])->String{list.withUnsafeBytes{Data($0).base64EncodedString()}}
var geometries:[[String:Any]]=[],geometryIDs:[ObjectIdentifier:Int]=[:]
func geometry(_ g:SCNGeometry)->Int{
    let id=ObjectIdentifier(g);if let i=geometryIDs[id]{return i};let i=geometries.count;geometryIDs[id]=i
    var out:[String:Any]=[:]
    for (semantic,name) in [(SCNGeometrySource.Semantic.vertex,"position"),(.normal,"normal"),(.texcoord,"uv")]{if let s=g.sources(for:semantic).first{out[name]=encoded(values(s));if name=="position"{out["vertexCount"]=s.vectorCount}}}
    precondition(out["position"] != nil,"No vertices in \(g)")
    var indices:[UInt32]=[],groups:[[String:Int]]=[]
    for (index,e) in g.elements.enumerated(){
        let count=e.data.count/e.bytesPerIndex
        let raw:[UInt32]=e.data.withUnsafeBytes{b in (0..<count).map{j in let o=j*e.bytesPerIndex;switch e.bytesPerIndex{case 1:return UInt32(b.loadUnaligned(fromByteOffset:o,as:UInt8.self));case 2:return UInt32(b.loadUnaligned(fromByteOffset:o,as:UInt16.self));default:return b.loadUnaligned(fromByteOffset:o,as:UInt32.self)}}}
        let start=indices.count
        if e.primitiveType == .triangles{indices.append(contentsOf:raw)}else if e.primitiveType == .triangleStrip{if raw.count>=3{for j in 2..<raw.count{let tri=j%2==0 ? [raw[j-2],raw[j-1],raw[j]]:[raw[j-1],raw[j-2],raw[j]];if Set(tri).count==3{indices.append(contentsOf:tri)}}}}else{preconditionFailure("Unsupported primitive \(e.primitiveType)")}
        groups.append(["start":start,"count":indices.count-start,"materialIndex":index%max(1,g.materials.count)])
    }
    out["index"]=encoded(indices);out["groups"]=groups;geometries.append(out);return i
}
func node(_ n:SCNNode)->[String:Any]{
    var out:[String:Any]=["name":n.name ?? "","matrix":matrix(n.transform),"hidden":n.isHidden,"children":n.childNodes.filter{$0.light==nil && $0.camera==nil && !($0.geometry is SCNFloor)}.map{node($0)}]
    if let g=n.geometry{out["geometry"]=geometry(g);out["materials"]=g.materials.map{mat($0)}};return out
}
// Bake demo pressings using the same seeded native material generator as the Mac app.
let titles=["Warm Frequencies","Blue Hour","Soft Geometry","Peach Radio","Night Windows","Golden Assembly"]
let palettes:[(NSColor,NSColor)]=[(color(0.73,0.34,0.18),color(0.96,0.76,0.44)),(color(0.08,0.28,0.36),color(0.63,0.80,0.76)),(color(0.62,0.66,0.48),color(0.18,0.28,0.20)),(color(0.87,0.58,0.47),color(0.48,0.18,0.18)),(color(0.18,0.22,0.38),color(0.83,0.70,0.56)),(color(0.78,0.59,0.25),color(0.28,0.25,0.18))]
let styles:[VinylVariant.Style]=[.black,.marble,.translucent,.twotone,.splatter,.marble]
var albums:[[String:Any]]=[]
for i in 0..<6{
    let art=NSImage(size:NSSize(width:800,height:800),flipped:false){r in
        let (base,ink)=palettes[i];fill(r,base)
        if i%3==0{ink.withAlphaComponent(0.6).setStroke();for j in 0..<10{let ring=NSBezierPath(ovalIn:NSRect(x:50+CGFloat(j)*30,y:70+CGFloat(j)*30,width:700-CGFloat(j)*60,height:700-CGFloat(j)*60));ring.lineWidth=3;ring.stroke()}}
        else if i%3==1{for j in 0..<9{fill(NSRect(x:CGFloat(j)*92,y:130,width:38,height:500),ink.withAlphaComponent(0.7))}}
        else{oval(NSRect(x:90,y:210,width:620,height:340),ink);oval(NSRect(x:350,y:260,width:210,height:210),base)}
        fill(NSRect(x:0,y:0,width:800,height:125),base);label(titles[i],NSRect(x:45,y:65,width:720,height:48),35,ink,.regular);label("RECORD ROOM / DEMO SERIES",NSRect(x:45,y:30,width:700,height:25),14,ink);return true
    }
    let key=(0..<10000).map{"web-demo-\(i)-\($0)"}.first{room.variant(for:art,key:$0).style==styles[i]}!
    let p=room.preparedPressing(art,key:key)!
    if i==0{room.sleeveFace.diffuse.contents=p.cover;room.discSurface.diffuse.contents=p.texture;room.discLabel.diffuse.contents=p.label;room.discEdge.diffuse.contents=p.variant.base}
    albums.append(["title":titles[i],"style":p.variant.name,"cover":imageFile(p.cover)!,"vinyl":imageFile(p.texture)!,"label":imageFile(p.label)!,"edge":rgba(p.variant.base)!])
}
let root=node(room.world.rootNode)
let environment=imageFile(room.world.lightingEnvironment.contents) ?? ""
let result:[String:Any]=["nodes":root,"geometries":geometries,"materials":materials,"albums":albums,"environment":environment,"camera":matrix(room.cameraNode.transform)]
try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:output.appendingPathComponent("room.json"))
print("Exported \(geometries.count) actual native geometries, \(materials.count) materials, \(textures.count) texture maps and six native pressings")
