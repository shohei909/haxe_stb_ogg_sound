import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;
// no rights reserved

class Ogg2WavTestSys
{
	public static function main() 
	{
		var dir = "sample/sound";
		for (file in FileSystem.readDirectory(dir)) {
			var parts = file.split(".");
			var inPath = dir + "/" + file;
			var outPath = dir + "/" + parts[0] + "-" + platform + ".wav";
			
			
			if (FileSystem.isDirectory(inPath)) continue;
			if (parts[1] != "ogg") continue;
			
			var input = File.read(inPath);
			var output = File.write(outPath);
			
			Ogg2Wav.convert(input, output);
			
			input.close();
			output.close();
		}
	}
	
	static var platform = 
	#if cs 
	"cs" 
	#elseif java 
	"java"
	#else
	""
	#end
	;
}
