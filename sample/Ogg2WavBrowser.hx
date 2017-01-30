package;

import haxe.io.Bytes;
import js.html.*;
import js.Browser.*;

class Ogg2WavBrowser
{
	static public var worker:js.html.Worker;

	static public function main()
	{
		// load worker script
		worker = new Worker('worker.js');
		
		// add handler for worker messages
		worker.onmessage = onWorkerMessage;
		
		// handle file loading events
		document.getElementById('files').addEventListener('change', handleFileSelect, false);
		
		// display initial message
		bodyTrace('Select one or many .ogg files to start background worker decoding');
	}

	static function onWorkerMessage(event)
	{
		// data is passed as array buffer for best worker <-> client performance
		var arrayBuffer: js.html.ArrayBuffer = event.data;
		
		// create a DataView for checking data size
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
			
			// do something useful with the WAV data here... :-)
			
		}
	}

	static function handleFileSelect(event)
	{
		var files:js.html.FileList = event.target.files; // FileList object
		for (f in files)
		{
			bodyTrace('Open file ' + f.name + ' ' + f.type + ' for deoding');
			
			// create 
			var reader = new js.html.FileReader();
			
			// take care of the file reader data
			reader.onload = function(evt)
			{
				// create an array buffer with the file data
				var arrayBuffer:js.html.ArrayBuffer = reader.result;

				// only use even number data length, otherwise browser error
				if (arrayBuffer.byteLength % 2 == 1) arrayBuffer = arrayBuffer.slice(0, arrayBuffer.byteLength - 1);
				
				bodyTrace( 'Client start sending arrayBuffer to worker...');
				
				// post the file data to the worker
				// trying to use arrayBuffer as transferable object for best performance
				// http://stackoverflow.com/questions/19152772/how-to-pass-large-data-to-web-workers
				worker.postMessage(arrayBuffer, [arrayBuffer]);
			}
			
			// kickoff the file reader
			reader.readAsArrayBuffer(f);
		}
	}

	// display message on web page
	static function bodyTrace(s:Dynamic)
	{
		document.body.appendChild(document.createTextNode(Std.string(s)));
		document.body.appendChild(document.createBRElement());
	};
}

