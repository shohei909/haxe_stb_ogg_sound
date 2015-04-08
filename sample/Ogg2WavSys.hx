import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import stb.format.vorbis.Reader;
import sys.FileSystem;
import sys.io.File;

class Ogg2WavSys
{
    public static function main()
    {
        var dir = "sample/sound";
        for (file in FileSystem.readDirectory(dir)) {
            if (file.substr(file.length - 4) != ".ogg") {
                continue;
            }

            var inPath = '$dir/$file';
            if (FileSystem.isDirectory(inPath)) {
                continue;
            }

            var outPath = '$dir/wav/$platform-${file.substr(0, file.length - 4)}.wav';

            Sys.println("File Name : " + inPath);

            var time = Date.now().getTime();
            var reader = Reader.openFromFile(inPath);
            var header = reader.header;
            var bitsPerSample = 16;
            var byteRate = Std.int(header.channel * header.sampleRate * bitsPerSample / 8);
            var blockAlign = Std.int(header.channel * bitsPerSample / 8);
            var dataLength = reader.totalSample * header.channel * 2;

            Sys.println("Channel : " + header.channel);
            Sys.println("Sample Rate : " + header.sampleRate);
            Sys.println("Sample : " + reader.totalSample);
            Sys.println("Time : " + Std.int(reader.totalMillisecond / 1000) + "sec");

            Sys.println("Vendor : " + header.vendor);

            var commentData = header.comment.data;
            for (key in commentData.keys()) {
                for (value in commentData[key]) {
                    Sys.println(key.toUpperCase() + "=" + value);
                }
            }

            //write wav header
            var output = File.write(outPath);
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

            while (true) {
                var time = Date.now().getTime();
                var n = reader.read(output, 500000);
                Sys.println('${reader.currentSample}/${reader.totalSample} : Decode Time ${lapTime(time)}');
                if (n == 0) break;
            }

            output.flush();
            output.close();
        }
    }

    static private function lapTime(time:Float)
    {
        return Std.int(Date.now().getTime() - time) + "ms";
    }

    static var platform =
    #if cs
    "cs"
    #elseif java
    "java"
    #elseif neko
    "neko"
    #else
    "other"
    #end
    ;
}
