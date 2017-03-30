package;

import haxe.io.Bytes;
import js.html.*;
import js.Browser.*;

using haxe.io.Path;

class Ogg2WavBrowser
{
	//static public var worker:js.html.Worker;

	static public function main()
	{
		// route haxe.Log.trace to web page display
		haxe.Log.trace = function( v : Dynamic, ?infos : haxe.PosInfos ) : Void
		{
			document.body.appendChild(document.createTextNode(Std.string(v)));
			document.body.appendChild(document.createBRElement());
		}
		
		trace('Select one or many .ogg files to start background worker decoding');		
		
		// create fileInput element
		var fileInput:InputElement = document.createInputElement();
		fileInput.id = 'files';
		fileInput.type = 'file';
		fileInput.multiple = true;
		fileInput.addEventListener('change', handleFileSelect, false);
		document.body.appendChild(fileInput);				
	}

	static function handleFileSelect(event)
	{
		var files:js.html.FileList = event.target.files; // FileList object
		for (file in files)
		{			
			if (! (file.name.extension().toLowerCase() == 'ogg')) continue;
			
			trace('Open file ' + file.name + ' ' + file.type + ' for decoding');
			
			// create 
			var reader = new js.html.FileReader();
			
			// take care of the file reader data
			reader.onload = function(evt)
			{
				// create an array buffer with the file data
				var arrayBuffer:js.html.ArrayBuffer = reader.result;

				// only use even number data length, otherwise browser error
				if (arrayBuffer.byteLength % 2 == 1) arrayBuffer = arrayBuffer.slice(0, arrayBuffer.byteLength - 1);
				
				trace( 'Client start sending arrayBuffer to worker...');

				// set up a new worker
				var worker = new Worker('worker.js');
				
				// callback to handle messages from the worker
				worker.onmessage = function(event) {
					// data is passed as array buffer for best worker <-> client performance
					var arrayBuffer: js.html.ArrayBuffer = event.data;
					
					// create a DataView for checking data size
					var dataView:DataView = new DataView(arrayBuffer);

					if (dataView.byteLength < 100) //  HACK ALERT! Small data chunk - treat as text message...
					{
						// Text message
						trace('- Message from worker: (' + file.name + ') ' + Bytes.ofData(arrayBuffer).toString());
					}
					else
					{
						// Data
						trace('Client recieved WAV data chunk of length ' + dataView.byteLength + ' from worker');
						
						var wavFilename = file.name.substr(0, file.name.lastIndexOf('.')) + '.wav';
						
						// do something useful with the WAV data here... :-)
						var wavBytes:ArrayBufferView = new Int8Array(arrayBuffer);
						saveFile(wavBytes, wavFilename);				
					}
				}
				
				// post the file data to the worker
				// trying to use arrayBuffer as transferable object for best performance
				// http://stackoverflow.com/questions/19152772/how-to-pass-large-data-to-web-workers
				worker.postMessage(arrayBuffer, [arrayBuffer]);
			}
			
			// kickoff the file reader
			reader.readAsArrayBuffer(file);
		}
	}

	// display message on web page
	static function bodyTrace(s:Dynamic)
	{
		document.body.appendChild(document.createTextNode(Std.string(s)));
		document.body.appendChild(document.createBRElement());
	};
	
	static  public function saveFile(data:ArrayBufferView, name:String) {
		var blob = new Blob([data], { type: "octet/stream" } ); 
		var url = URL.createObjectURL(blob);		
		var a = document.createAnchorElement();
		document.body.appendChild(a);				
		a.href = url;
		a.download = name;
		a.click();		
		URL.revokeObjectURL(url);
	};	
}

