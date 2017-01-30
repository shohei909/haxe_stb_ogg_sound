package;

import haxe.io.Bytes;
import js.html.*;
import js.Browser.*;

class Ogg2WavBrowser
{
	static public var worker:js.html.Worker;

	static public function main()
	{
		worker = new Worker('worker.js');
		worker.onmessage = onWorkerMessage;
		document.getElementById('files').addEventListener('change', handleFileSelect, false);
		bodyTrace('Select one or many .ogg files to start background worker decoding');
	}

	static function onWorkerMessage(event)
	{
		var arrayBuffer: js.html.ArrayBuffer = event.data;
		var dataView:DataView = new DataView(arrayBuffer);

		if (dataView.byteLength < 100) //  HACK ALERT! Small data chunk - treat as text message...
		{
			// Text message
			bodyTrace('- Message from worker: ' + Bytes.ofData(arrayBuffer).toString());
		}
		else
		{
			// Data
			bodyTrace('Client recieved WAV data chunk of length ' + dataView.byteLength + ' from worker');
		}
	}

	static function handleFileSelect(event)
	{
		var files:js.html.FileList = event.target.files; // FileList object
		for (f in files)
		{
			bodyTrace(f.name + ' ' + f.type);
			var reader = new js.html.FileReader();
			reader.onload = function(evt)
			{
				var arrayBuffer:js.html.ArrayBuffer = reader.result;

				// Only use even number length
				if (arrayBuffer.byteLength % 2 == 1) arrayBuffer = arrayBuffer.slice(0, arrayBuffer.byteLength - 1);
				
				bodyTrace( 'Client start sending arrayBuffer to worker...');
				worker.postMessage(arrayBuffer, [arrayBuffer]);
			}
			reader.readAsArrayBuffer(f);
		}
	}

	static function bodyTrace(s:Dynamic)
	{
		var body:js.html.Element =document.getElementById('body');
		body.appendChild(document.createTextNode(Std.string(s)));
		body.appendChild(document.createBRElement());
	};
}

