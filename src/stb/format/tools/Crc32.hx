package stb.format.tools;
import haxe.ds.Vector;

/**
 * ...
 * @author shohei909
 */
class Crc32
{
    static inline var POLY:UInt = 0x04c11db7;
    static var table:Vector<UInt>;

    public static function init() {
        if (table != null) {
            return;
        }
        
		var uSign : UInt = cast ( 1 << 31 );
		
        table = new Vector(256);
        for (i in 0...256) {
            var s:UInt = ((i:UInt) << (24:UInt));
            for (j in 0...8) {
                s = (s << 1) ^ (s >= uSign ? POLY : 0);
            }
            table[i] = s;
        }
    }

    public static inline function update(crc:UInt, byte:UInt):UInt
    {
        return (crc << 8) ^ table[byte ^ (crc >>> 24)];
    }
}
