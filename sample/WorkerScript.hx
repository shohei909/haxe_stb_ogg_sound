
package;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import js.html.ArrayBuffer;
import stb.format.vorbis.Reader;

class WorkerScript
{
	public static function __init__()
	{
		untyped __js__("onmessage = WorkerScript.prototype.messageHandler");
	}

	// handle messages sent from client
	public function messageHandler(event)
	{
		// handle event data as arrayBuffer
		var arrayBuffer:js.html.ArrayBuffer = cast event.data;
		
		// convert to haxe.io.Bytes
		var bytes:Bytes = Bytes.ofData(arrayBuffer);
		
		// kick of the Vorbis Reader 
		var reader = Reader.openFromBytes(bytes);

		// get some metadata
		var header = reader.header;
		var bitsPerSample = 16;
		var byteRate = Std.int(header.channel * header.sampleRate * bitsPerSample / 8);
		var blockAlign = Std.int(header.channel * bitsPerSample / 8);
		var dataLength = reader.totalSample * header.channel * 2;

		postMessage(stringToArrayBuffer("Channel : " + header.channel));
		postMessage(stringToArrayBuffer("Sample Rate : " + header.sampleRate));
		postMessage(stringToArrayBuffer("Sample : " + reader.totalSample));
		postMessage(stringToArrayBuffer("Time : " + Std.int(reader.totalMillisecond / 1000) + "sec"));
		postMessage(stringToArrayBuffer("Vendor : " + header.vendor));
		
		var commentData = header.comment.data;
		for (key in commentData.keys())
		{
			for (value in commentData[key])
			{
				postMessage(stringToArrayBuffer(key.toUpperCase() + "=" + value));
			}
		}

		//------------------------------------------------------------------------------
		
		// create an instance of haxe.io.Output to be populated with WAV data by the Vorbis Reader
		var output = new BytesOutput();
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

		postMessage(stringToArrayBuffer('Start decoding ogg data...'));
		while (true)
		{
			var time = Date.now().getTime();
			
			// decode OGG chunks and write WAV data to output
			var n = reader.read(output, 500000);
			postMessage(stringToArrayBuffer('${reader.currentSample}/${reader.totalSample} : Decode Time ${lapTime(time)}'));
			if (n == 0) break;
		}

		// close the output
		output.flush();
		output.close();

		postMessage(stringToArrayBuffer('Ogg decoding completed!'));
		
		// get the output data as ArrayBuffer 
		var outputArrayBuffer:js.html.ArrayBuffer = output.getBytes().getData();
		
		// post the WAV data to the client
		// trying to use arrayBuffer as transferable object for best performance
		// http://stackoverflow.com/questions/19152772/how-to-pass-large-data-to-web-workers		
		postMessage(outputArrayBuffer, [outputArrayBuffer]);
	}
	
	inline public function stringToArrayBuffer(msg:String):ArrayBuffer  return Bytes.ofString(msg.substr(0, 99)).getData();

	@:pure(false) 
	public function postMessage(message, ?messageArray)
	{
		// At runtime, this postMessage method is overridden by an implicit JavaScript enginge method
		// but Haxe needs an explicit method at compile time
	}

	static private function lapTime(time:Float)
	{
		return Std.int(Date.now().getTime() - time) + "ms";
	}
}