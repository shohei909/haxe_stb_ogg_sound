// no rights reserved
import flash.display.Sprite;
import flash.events.Event;
import flash.events.MouseEvent;
import flash.Lib;
import flash.media.SoundChannel;
import flash.media.SoundTransform;
import flash.net.FileFilter;
import flash.net.FileReference;
import flash.text.TextField;
import flash.text.TextFieldAutoSize;
import flash.utils.ByteArray;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import stb.format.vorbis.Reader;

class Ogg2WavFlash extends Sprite
{	
	static private var state:State;
	static private var textField:TextField;
	
	public static function main() 
	{
		Lib.current.stage.addEventListener(MouseEvent.MOUSE_DOWN, onDown);
		Lib.current.stage.addEventListener(Event.ENTER_FRAME, onFrame);
		
		textField = new TextField();
		textField.autoSize = TextFieldAutoSize.LEFT;
		Lib.current.addChild(textField);
		
		updateState(State.WaitClick);
	}
	
	static private function updateState(nextState:State) 
	{
		if (state != null) {
			switch(state) {
				case WaitClick:
					
				case FileBrowse(fileReference, onLoadSelect, onCancel):
					fileReference.removeEventListener(Event.SELECT, onLoadSelect);
					fileReference.removeEventListener(Event.CANCEL, onCancel);
				
				case FileLoad(fileReference, onComplete):
					fileReference.removeEventListener(Event.COMPLETE, onComplete);
					
				case Decode(_):
					
				case FileSave(fileReference, name, data, onSaveSelect, onCancel):
					fileReference.removeEventListener(Event.SELECT, onSaveSelect);
					fileReference.removeEventListener(Event.CANCEL, onCancel);
			}
		}
		
		switch(nextState) {
			case WaitClick:
				textField.text = "Click to select .ogg file";
				
			case FileBrowse(fileReference, onLoadSelect, onCancel):
				textField.text = "Select .ogg file";
				fileReference.addEventListener(Event.SELECT, onLoadSelect);
				fileReference.addEventListener(Event.CANCEL, onCancel);
				fileReference.browse([new FileFilter("Ogg Vorbis File", "*.ogg")]);
				
			case FileLoad(fileReference, onComplete):
				textField.text = "Reading...";
				fileReference.addEventListener(Event.COMPLETE, onComplete);
				fileReference.load();
				
			case Decode(reader, _):
				textField.text = "Converting...";
				
			case FileSave(fileReference, name, data, onSaveSelect, onCancel):
				textField.text = "Save";
				fileReference.addEventListener(Event.SELECT, onSaveSelect);
				fileReference.addEventListener(Event.CANCEL, onCancel);
				fileReference.save(data, name + ".wav");
		}
		
		state = nextState;
	}
	
	static private function onDown(e:MouseEvent):Void {
		switch (state) {
			case WaitClick:
				var f = new FileReference();
				updateState(FileBrowse(f, onLoadSelect.bind(f), onCancel));
				
			case _:
		}
	}
	
	static private function onFrame(e:Event):Void 
	{
		switch (state) {
			case Decode(reader, output, name, onDecode):
				var n = reader.read(output, reader.header.sampleRate);
				if (n == 0) {
					onDecode(reader, output, name);
				}
				textField.text = 'Converting...${reader.currentSample}/${reader.totalSample} (${Std.int(reader.currentSample / reader.totalSample * 100)}%)';
				
			case _:
		}
	}
	
	static private function onLoadSelect(fileReference:FileReference, e:Event) {
		updateState(FileLoad(fileReference, onComplete.bind(fileReference)));
	}
	
	static private function onComplete(fileReference:FileReference, e:Event) {
		var name = fileReference.name;
		
		if (name.substr(-4) == ".ogg") {
			name = name.substr(0, name.length - 4);
		}
		
		var reader = Reader.openFromBytes(Bytes.ofData(fileReference.data));
		var header = reader.header;
		var bitsPerSample = 16;
		var byteRate = Std.int(header.channel * header.sampleRate * bitsPerSample / 8);
		var blockAlign = Std.int(header.channel * bitsPerSample / 8);
		var dataLength = reader.totalSample * header.channel * 2;
		
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
		
		updateState(Decode(reader, output, name, onDecode));
	}
	
	static private function onDecode(reader:Reader, output:BytesOutput, name:String) {
		
		updateState(FileSave(new FileReference(), name, output.getBytes().getData(), onSaveSelect, onCancel));
		output.close();
	}
	
	static private function onSaveSelect(e:Event) 
	{
		updateState(WaitClick);
	}
	
	static private function onCancel(e:Event) 
	{
		updateState(WaitClick);
	}
	
	static private function lapTime(time:Float) 
	{
		return Std.int((Date.now().getTime() - time)) + "ms";
	}
}

enum State {
	WaitClick;
	FileBrowse(fileRefernce:FileReference, onSelect:Event->Void, onCancel:Event->Void);
	FileLoad(fileRefernce:FileReference, onComplete:Event->Void);
	Decode(reader:Reader, output:BytesOutput, name:String, onDecode:Reader->BytesOutput->String->Void);
	FileSave(fileRefernce:FileReference, name:String, data:ByteArray, onSelect:Event->Void, onCancel:Event->Void);
}
