import haxe.io.Bytes;
import haxe.io.Output;
import js.node.Buffer;
import js.node.Fs;
import stb.format.vorbis.Reader;

class Ogg2WavNodejs
{

	static public function main()
	{
		var platform = 'nodejs';
		var dir = "sample/sound";
		
		for (file in sys.FileSystem.readDirectory(dir))
		{
			if (file.substr(file.length - 4) != ".ogg") continue;
			var inPath = '$dir/$file';
			if (sys.FileSystem.isDirectory(inPath)) continue;
			var outPath = '$dir/wav/$platform-${file.substr(0, file.length - 4)}.wav';
			Sys.println("File Name : " + inPath);
			var bytes = sys.io.File.getBytes(inPath);
			var reader = Reader.openFromBytes(bytes);

			var header = reader.header;
			var bitsPerSample = 16;
			var byteRate = Std.int(header.channel * header.sampleRate * bitsPerSample / 8);
			var blockAlign = Std.int(header.channel * bitsPerSample / 8);
			var dataLength = reader.totalSample * header.channel * 2;

			Sys.println("Channel : " + header.channel);
			Sys.println("Sample Rate : " + header.sampleRate);
			Sys.println("Sample : " + reader.totalSample);
			Sys.println("Time : " + Std.int(reader.totalMillisecond / 1000) + "sec");
			Sys.println("Vendor : " + header.vendor);

			var commentData = header.comment.data;
			for (key in commentData.keys())
			{
				for (value in commentData[key])
				{
					Sys.println(key.toUpperCase() + "=" + value);
				}
			}

			var output = new FakeNodejsFileOutput(outPath, reader.totalSample*8);
			output.bigEndian = false;
			output.writeString("RIFF");
			output.writeInt32(36 + dataLength);
			output.writeString("WAVEfmt ");
			output.writeInt32(16);
			output.writeUInt16(1);
			output.writeUInt16(header.channel);
			output.writeInt32(header.sampleRate);
			output.writeInt32(byteRate);
			output.writeUInt16(blockAlign);
			output.writeUInt16(bitsPerSample);
			output.writeString("data");
			output.writeInt32(dataLength);
			while (true)
			{
				var time = Date.now().getTime();
				var n = reader.read(output, 500000);
				Sys.println('${reader.currentSample}/${reader.totalSample} : Decode Time ${lapTime(time)}');
				if (n == 0) break;
			}
			output.flush();
			output.close();
		}

	}
	
	static private function lapTime(time:Float)
	{
		return Std.int(Date.now().getTime() - time) + "ms";
	}

}

// Simple solution to make FileOutput working on nodejs - not a complete implmementation!
class FakeNodejsFileOutput extends Output {
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
}
