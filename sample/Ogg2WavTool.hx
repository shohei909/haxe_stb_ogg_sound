import sys.FileSystem;
import sys.io.File;
// no rights reserved

class Ogg2WavTool
{
	public static function main() 
	{
		var args = Sys.args();
		if (args.length != 2) {
			error("invalid arguments");
		}
		
		var oggFile = args[0];
		var wavFile = args[1];
		
		if (!FileSystem.exists(oggFile) || FileSystem.isDirectory(oggFile)) {
			error("input file not found");
		}
		
		if (FileSystem.exists(wavFile)) {
			error("output file already exists");
		}
		
		var input = File.read(oggFile);
		var output = File.write(wavFile);
		
		Ogg2Wav.convert(input, output);
		
		input.close();
		output.close();
	}
	
	static function error(message:String) {
		Sys.stderr().writeString(message + "\n");
		printUsage();
		Sys.exit(1);
	}
	
	static function printUsage() {
		Sys.println("Usage: ogg2wav [input file] [output file]");
	}
}
