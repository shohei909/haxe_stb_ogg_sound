// no rights reserved
import flash.display.Sprite;
import flash.events.Event;
import flash.events.MouseEvent;
import flash.Lib;
import flash.net.FileFilter;
import flash.net.FileReference;
import flash.text.TextField;
import flash.text.TextFieldAutoSize;
import flash.utils.ByteArray;
import format.wav.Data.WAVEFormat;
import format.wav.Writer;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import stb.format.ogg.Reader;

class Ogg2WavTestFlash extends Sprite
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
				textField.text = "画面をクリックして、.oggファイルを選択してください。";
				
			case FileBrowse(fileReference, onLoadSelect, onCancel):
				textField.text = ".oggファイルを選択してください。";
				fileReference.addEventListener(Event.SELECT, onLoadSelect);
				fileReference.addEventListener(Event.CANCEL, onCancel);
				fileReference.browse([new FileFilter("Ogg Vorbis File", "*.ogg")]);
				
			case FileLoad(fileReference, onComplete):
				textField.text = "読みこみ中...";
				fileReference.addEventListener(Event.COMPLETE, onComplete);
				fileReference.load();
				
			case Decode(reader, _):
				textField.text = "変換中...";
				reader.open();
				
			case FileSave(fileReference, name, data, onSaveSelect, onCancel):
				textField.text = "保存してください";
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
			case Decode(reader, buffer, name, onDecode):
				for (i in 0...25) {
					var n = reader.read(buffer);
					if (n == 0) {
						onDecode(reader, buffer, name);
						break;
					}
				}
				textField.text = "変換中..." + buffer.length;
				
			case _:
		}
	}
	
	static private function onLoadSelect(fileReference:FileReference, e:Event) {
		updateState(FileLoad(fileReference, onComplete.bind(fileReference)));
	}
	
	static private function onComplete(fileReference:FileReference, e:Event) {
		var reader = new Reader(new BytesInput(Bytes.ofData(fileReference.data)));
		var name = fileReference.name;
		
		if (name.substr(-4) == ".ogg") {
			name = name.substr(0, name.length - 4);
		}
		
		updateState(Decode(reader, [], name, onDecode));
	}
	
	static private function onDecode(reader:Reader, data:Array<Float>, name:String) {
		var bo = new BytesOutput();
		for (i in data) {
			bo.writeInt16(Math.floor(i * 0x7FFF));
		}
		bo.flush();
		
		var wavOutput = new BytesOutput();
		var writer = new Writer(wavOutput);
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
		
		updateState(FileSave(new FileReference(), name, wavOutput.getBytes().getData(), onSaveSelect, onCancel));
		wavOutput.close();
	}
	
	static private function onSaveSelect(e:Event) 
	{
		updateState(WaitClick);
	}
	
	static private function onCancel(e:Event) 
	{
		updateState(WaitClick);
	}
}

enum State {
	WaitClick;
	FileBrowse(fileRefernce:FileReference, onSelect:Event->Void, onCancel:Event->Void);
	FileLoad(fileRefernce:FileReference, onComplete:Event->Void);
	Decode(reader:Reader, buffer:Array<Float>, name:String, onDecode:Reader->Array<Float>->String->Void);
	FileSave(fileRefernce:FileReference, name:String, data:ByteArray, onSelect:Event->Void, onCancel:Event->Void);
}
