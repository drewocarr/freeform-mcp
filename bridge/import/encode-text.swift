import AppKit
import Foundation
let args=CommandLine.arguments
let specifications=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String:Any]]
let base=try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String:Any]]
var output=base
func archive(_ value: Any) throws -> String { try NSKeyedArchiver.archivedData(withRootObject:value,requiringSecureCoding:false).base64EncodedString() }
func model(_ type:String,_ fields:[String:Any]) -> [String:Any] { fields.merging(["type_identifier":"com.apple.apps.content-language."+type,"version":"1.0"]) { a,_ in a } }
for specification in specifications {
    let text=specification["text"] as! String
    let size=specification["size"] as! Double
    let width=specification["width"] as! Double
    let x=specification["x"] as! Double
    let baseline=specification["baseline"] as! Double
    let bold=specification["bold"] as! Bool
    let rgb=specification["color"] as! [Double]
    var font=NSFont.systemFont(ofSize:size,weight:bold ? .bold : .regular)
    let measured=(text as NSString).size(withAttributes:[.font:font]).width
    if measured>width { font=NSFont.systemFont(ofSize:size*width/measured,weight:bold ? .bold : .regular) }
    let paragraph=NSMutableParagraphStyle();paragraph.alignment = .left;paragraph.lineBreakMode = .byClipping
    let attributes=["NSFont":try archive(font),"NSColor":try archive(NSColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)),"NSParagraphStyle":try archive(paragraph)]
    let height=ceil(font.ascender-font.descender+font.leading)+4
    let w=width+4
    var object=base[0]
    object["description"]=""
    object["fill"]=model("fill",["primary_case":"color","color":model("color",["primary_case":"rgba","rgba":model("color.rgba",["red":1,"green":1,"blue":1,"alpha":0,"headroom":1,"color_space":"srgb","version":"1.1"])])])
    object["opacity"]=1
    object["path"]=model("path",["primary_case":"bezier","bezier":model("path.bezier-path",["path":"M 0 0 L \(w) 0 L \(w) \(height) L 0 \(height) Z"])])
    object["geometry"]=model("geometry",["position":model("position",["x":x,"y":baseline-font.ascender]),"size":model("size",["width":w,"height":height]),"flip_horizontally":false,"width_valid":true,"height_valid":true,"angle":0])
    object["text"]=model("text",["primary_case":"attributed_string","attributed_string":[text,attributes]])
    output.append(object)
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[3]))
print("Encoded \(base.count) vectors and \(specifications.count) editable text lines")
