package;
import flash.display.Graphics;
import flash.display.Shape;
import flash.display.Sprite;
import flash.events.Event;
import flash.events.MouseEvent;
import flash.filters.BlurFilter;
import flash.geom.Rectangle;
import flash.Lib;
import flash.media.Sound;
import flash.media.SoundChannel;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.text.TextFormatAlign;
import flash.utils.ByteArray;
import haxe.io.Bytes;
import stb.format.vorbis.flash.VorbisSound;
import stb.format.vorbis.flash.VorbisSoundChannel;

/**
 * @author shohei909
 */
class VorbisSoundPlayer
{
    public static function main() {
        var bytes = Bytes.ofData(new SoundData());
        var sound = new VorbisSound(bytes);
        var button = new PlayerSprite(sound);
        button.x = 10;
        button.y = 10;
        Lib.current.addChild(button);
    }
}

@:file("sound/Air_(Bach).ogg")
class SoundData extends ByteArray {}

private class PlayerSprite extends Sprite {
    var buttonLight:Shape;
    var barLight:Shape;

    var buttonBackground:Shape;
    var barBackground:Shape;
    var pinBackground:Shape;

    var buttonForeground:Shape;
    var barForeground:Shape;
    var pinForeground:Shape;

    var textField:TextField;
    var sound:VorbisSound;
    var state:PlayerState;
    var position:Float = 0;

    var buttonDepth:Float = 0;
    var mouseState:MouseState;
    var barRect:Rectangle;

    var playing(get, never):Bool;
    function get_playing():Bool {
        return switch[state, mouseState] {
            case [PlayerState.Playing, _] | [_, MouseState.DownBar(true)]:
                true;
            case _:
                false;
        }
    }

    public static var MARGIN = 12;
    public static var BUTTON_W = 35;
    public static var H = 35;
    public static var BAR_W = 300;
    public static var TEXT_W = 80;

    public function new(sound:VorbisSound) {
        super();
        this.sound = sound;
        mouseState = MouseState.None;
        state = PlayerState.Stop;

        addChild(buttonLight = new Shape());
        addChild(barLight = new Shape());

        addChild(buttonBackground = new Shape());
        addChild(barBackground = new Shape());
        addChild(pinBackground = new Shape());
        addChild(buttonForeground = new Shape());
        addChild(barForeground = new Shape());
        addChild(pinForeground = new Shape());

        //text
        addChild(textField = new TextField());
        textField.defaultTextFormat = new TextFormat("_sans", 12, 0x8D8E8F, true, false, false, null, null, TextFormatAlign.CENTER);
        textField.width = TEXT_W;
        textField.height = 19;
        textField.x = BUTTON_W + 1 + MARGIN + BAR_W + MARGIN;
        textField.y = (H - 19) / 2;

        draw();

        barRect = new Rectangle(BUTTON_W + 1, 0, MARGIN * 2 + BAR_W, H);
        buttonDepth = 0;
        onFrame(null);

        addEventListener(MouseEvent.MOUSE_DOWN, onMouseDown);
        addEventListener(Event.ENTER_FRAME, onFrame);
        this.mouseChildren = false;
    }

    function draw() {

        // light
        var g = buttonLight.graphics;
        g.clear();
        g.beginFill(0x8796F6);
        drawButtonOuter(g, 6);
        g.endFill();

        var g = barLight.graphics;
        g.clear();
        g.beginFill(0xF6F5F4);
        drawBarOuter(g, 6);
        g.endFill();


        //background
        var g = buttonBackground.graphics;
        g.clear();
        g.beginFill(0);
        drawButtonOuter(g, 4);
        drawButtonInner(g);
        g.endFill();
        buttonBackground.filters = [new BlurFilter(6, 6)];
        buttonBackground.alpha = 0.25;


        var g = barBackground.graphics;
        g.clear();
        g.beginFill(0);
        drawBarOuter(g, 4);
        drawBarInner(g, 7);
        g.endFill();
        barBackground.filters = [new BlurFilter(6, 6)];
        barBackground.alpha = 0.25;

        var g = pinBackground.graphics;
        g.clear();
        g.beginFill(0);
        g.drawCircle(0, 0, 4);
        pinBackground.filters = [new BlurFilter(6, 6)];
        pinBackground.alpha = 0.25;


        //foreground
        var g = buttonForeground.graphics;
        g.clear();
        g.beginFill(0xFFFFFF);
        drawButtonOuter(g, 5);
        drawButtonInner(g);
        buttonForeground.graphics.endFill();

        barForeground.graphics.beginFill(0xFFFFFF);
        drawBarOuter(barForeground.graphics, 5);
        drawBarInner(barForeground.graphics, 6);
        barForeground.graphics.endFill();

        pinForeground.graphics.beginFill(0xFFFFFF);
        pinForeground.graphics.drawCircle(0, 0, 4);
    }

    function onMouseDown(e:MouseEvent) {
        if (barRect.contains(mouseX, mouseY)) {
            switch (state) {
                case PlayerState.Playing(channel):
                    changeMouseState(MouseState.DownBar(true));
                    stop(channel);

                case PlayerState.Stop:
                    changeMouseState(MouseState.DownBar(false));
            }
        } else if (buttonForeground.hitTestPoint(e.stageX, e.stageY)) {
            buttonDepth = 1;
            changeMouseState(MouseState.DownButton);
        } else {
            changeMouseState(MouseState.None);
        }
    }

    function onMouseUp(e:MouseEvent) {
        switch (mouseState) {
            case MouseState.None:
            case MouseState.DownBar(playing):
                movePin();
                if (playing) {
                    play();
                }

            case MouseState.DownButton:
                togglePlayState();
        }

        changeMouseState(MouseState.None);
    }

    function togglePlayState() {
        switch (state) {
            case PlayerState.Playing(channel):
                stop(channel);

            case PlayerState.Stop:
                play();
        }
    }

    function stop(channel:VorbisSoundChannel) {
        channel.removeEventListener(Event.SOUND_COMPLETE, onSoundComplete);
        channel.stop();
        state = PlayerState.Stop;
        draw();
    }

    function play() {
        var channel = sound.play(position, 0x7FFFFFFF);
        channel.addEventListener(Event.SOUND_COMPLETE, onSoundComplete);
        state = PlayerState.Playing(channel);
        draw();
    }

    function onSoundComplete(e:Event):Void {
        switch (state) {
            case PlayerState.Playing(channel):
                stop(channel);

            case PlayerState.Stop:
        }
    }

    function changeMouseState(newState:MouseState) {
        if (this.mouseState != null) {
            switch (this.mouseState) {
                case MouseState.None:
                case MouseState.DownBar | MouseState.DownButton:
                    stage.removeEventListener(MouseEvent.MOUSE_UP, onMouseUp);
            }
        }

        this.mouseState = newState;

        switch (mouseState) {
            case MouseState.None:
            case MouseState.DownBar | MouseState.DownButton:
                stage.addEventListener(MouseEvent.MOUSE_UP, onMouseUp);
        }
    }

    function onFrame(e) {
        switch (mouseState) {
            case MouseState.None:
                buttonDepth = buttonDepth / 2;

            case MouseState.DownBar:
                movePin();

            case MouseState.DownButton:
        }

        switch (state) {
            case PlayerState.Playing(channel):
                position = channel.position;

            case PlayerState.Stop:
        }

        var barStart = BUTTON_W + 1 + (H / 2);
        var barLength = MARGIN + BAR_W + MARGIN - H;
        var px = barStart + barLength * (position / sound.length);
        pinBackground.x = pinForeground.x = px;
        pinBackground.y = pinForeground.y = H / 2;
        buttonBackground.alpha = 0.25 * (1 - buttonDepth);

        textField.text = toTimeText(position) + "/" + toTimeText(sound.length);
    }

    function movePin() {
        var barStart = BUTTON_W + 1 + (H / 2);
        var barLength = MARGIN + BAR_W + MARGIN - H;
        var rate = (mouseX - barStart) / barLength;
        if (rate < 0) {
            rate = 0;
        } else if (rate > 1) {
            rate = 1;
        }
        position = sound.length * rate;
    }

    function toTimeText(soundLength:Float) {
        var sec = Math.floor(soundLength / 1000);
        var min = Math.floor(sec / 60);
        sec -= min * 60;
        var str = min + ":" + Std.string(100 + sec).substr(-2);
        while (str.length < 5) {
            str = "0" + str;
        }
        return str;
    }

    function drawButtonOuter(g:Graphics, round:Int) {
        g.moveTo(BUTTON_W, 0);
        g.lineTo(BUTTON_W, H);
        g.lineTo(round, H);
        g.curveTo(0, H, 0, H - round);
        g.lineTo(0, round);
        g.curveTo(0, 0, round, 0);
        g.lineTo(BUTTON_W, 0);
    }

    function drawButtonInner(g:Graphics) {
        if (playing) {
            //pause button
            g.moveTo(BUTTON_W * 2 / 9, H * 1 / 4);
            g.lineTo(BUTTON_W * 4 / 9, H * 1 / 4);
            g.lineTo(BUTTON_W * 4 / 9, H * 3 / 4);
            g.lineTo(BUTTON_W * 2 / 9, H * 3 / 4);

            g.moveTo(BUTTON_W * 7 / 9, H * 1 / 4);
            g.lineTo(BUTTON_W * 5 / 9, H * 1 / 4);
            g.lineTo(BUTTON_W * 5 / 9, H * 3 / 4);
            g.lineTo(BUTTON_W * 7 / 9, H * 3 / 4);
        } else {
            //play button
            g.moveTo(BUTTON_W / 3, H / 4);
            g.lineTo(BUTTON_W / 3, H * 3 / 4);
            g.lineTo(BUTTON_W * 3 / 4, H / 2);
        }
    }

    function drawBarOuter(g:Graphics, round:Int) {
        var l = BUTTON_W + 1;
        var r = BUTTON_W + 1 + MARGIN + BAR_W + MARGIN + TEXT_W + MARGIN;
        g.moveTo(r - round, 0);
        g.curveTo(r, 0, r, round);
        g.lineTo(r, H - round);
        g.curveTo(r, H, r - round, H);
        g.lineTo(l, H);
        g.lineTo(l, 0);
        g.lineTo(r - round, 0);
    }

    function drawBarInner(g:Graphics, round:Int) {
        var l = BUTTON_W + 1 + MARGIN;
        var u = MARGIN;
        var r = BUTTON_W + 1 + MARGIN + BAR_W;
        var d = H - MARGIN;

        g.moveTo(r - round, u);
        g.lineTo(l + round, u);
        g.curveTo(l, u, l, u + round);
        g.lineTo(l, d - round);
        g.curveTo(l, d, l + round, d);
        g.lineTo(r - round, d);
        g.curveTo(r, d, r, d - round);
        g.lineTo(r, u + round);
        g.curveTo(r, u, r - round, u);
    }
}

enum PlayerState {
    Stop;
    Playing(channel:VorbisSoundChannel);
}

enum MouseState {
    None;
    DownButton;
    DownBar(playing:Bool);
}
