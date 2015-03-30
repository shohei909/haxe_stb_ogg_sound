// no rights reserved

import haxe.io.Input;
import haxe.io.Output;
import stb.format.ogg.Reader;
import format.wav.Data.WAVE;
import format.wav.Data.WAVEFormat;
import format.wav.Writer;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

class Ogg2Wav {
	static public function convert(input:Input, output:Output) {
		
		var reader = new Reader(input);
		var bo = new BytesOutput();
		reader.readAll(bo);
		bo.flush();
		
		var writer = new Writer(output);
		writer.write({
			header : {
				format : WAVEFormat.WF_PCM,
				channels : reader.channels,
				samplingRate : reader.sampleRate,
				byteRate : reader.channels * reader.sampleRate * 2,		// samplingRate * channels * bitsPerSample / 8
				bitsPerSample : 16,
				blockAlign : reader.channels * 2,	 // channels * bitsPerSample / 8
			},
			data : bo.getBytes() 
		});
		output.close();
	}
}
