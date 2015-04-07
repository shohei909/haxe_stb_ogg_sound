package stb.format.vorbis.flash;

import flash.events.IEventDispatcher;
import flash.events.SampleDataEvent;
import flash.media.SoundTransform;
import flash.media.Sound;
import flash.media.SoundChannel;
import haxe.io.Bytes;
import stb.format.vorbis.Reader;

class VorbisSound {
	var rootReader:Reader;
	public var length(default, null):Float;
	
	public function new(bytes:Bytes) {
		rootReader = Reader.openFromBytes(bytes);
		length = rootReader.totalMillisecond;
	}
	
	public function play(startTime:Float, loops:Int = 0, ?sndTransform:SoundTransform):VorbisSoundChannel {
		var sound = new Sound();
		var reader = rootReader.clone();
		return VorbisSoundChannel.play(sound, reader, startTime, loops, startTime, sndTransform);
	}
}
