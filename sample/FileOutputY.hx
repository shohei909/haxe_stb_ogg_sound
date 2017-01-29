package cx.node;
import haxe.io.Bytes;
import haxe.io.Output;
/**
 * FileOutputY
 * @author Jonas Nyström
 */
class FileOutputY extends Output {
	#if nodejs
	var o:js.node.fs.WriteStream;
	var b:js.node.Buffer;
	var offset:Int;
	
	public function new(path:String, bufferSize:Int=60000000) {
		this.o = js.node.Fs.createWriteStream(path);			
		this.b = new js.node.Buffer(bufferSize);				
		this.offset = 0; 
	}
	
	override public function writeInt16(val:Int) {
		(this.bigEndian) ? b.writeInt16BE(val, offset) : b.writeInt16LE(val, offset);
		offset += 2;		
	}
	
	override public function writeUInt16(val:Int) {
		(this.bigEndian) ? b.writeUInt16BE(val, offset) : b.writeUInt16LE(val, offset);
		offset += 2;		
	}
	
	override public function writeInt32(val:Int) {
		(this.bigEndian) ? b.writeInt32BE(val, offset) : b.writeInt32LE(val, offset);
		offset += 4;		
	}	
	
	override public function writeByte( c : Int ) : Void {
		var str = String.fromCharCode(c);		
		b.write(str, offset);
		offset += str.length;		
	}
	
	override public function writeBytes( s : Bytes, pos : Int, len : Int ) : Int {
		var str = s.toString().substr(pos, len);		
		b.write(str, offset);	
		offset += str.length;
		return str.length;		
	}
	
	override public function close() {
		this.o.write(b.slice(0,this.offset));
		this.o.end();			
	}	
	#end
}