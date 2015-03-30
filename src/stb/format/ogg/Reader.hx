package stb.format.ogg;

import haxe.io.BytesOutput;
import haxe.io.Output;
import stb.format.ogg.Data;
import stb.format.tools.MathTools;
import stb.format.tools.Mdct;

import haxe.ds.Vector;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.PosInfos;

/**
 * public domain ogg reader.
 * @author shohei909
 */
class Reader
{	
	static inline var NO_CODE = 255;
	static inline var EOP = -1;
	static inline var INVALID_BITS = -1;
	static inline var M_PI = 3.14159265358979323846264;
	
	static var DIVTAB_NUMER = 32;
	static var DIVTAB_DENOM = 64;
	static var integerDivideTable:Vector<Vector<Int>>;
	
	public var sampleRate(default, null):UInt; 
	public var channels(default, null):Int;

	//var setupMemoryRequired:Int;
	//var setupTempMemoryRequired:Int = 0;
	//var tempMemoryRequired:Int;
	
	var stream:Input;		 //uint8 *
	
	var firstAudioPageOffset:UInt = 0; //uint32 
	var pFirst:ProbedPage;
	//var pLast:ProbedPage;

	// memory management
	//stbVorbis_alloc alloc;
	//var setupOffset:Int;
	//var tempOffset:Int;

	// run-time results
	var eof:Bool = false;

	// user-useful data

	// header info
	var blocksize0:Int; 
	var blocksize1:Int;
	var codebooks:Vector<Codebook>;
	var floorTypes:Vector<Int>; // uint16 [64] varies
	var floorConfig:Vector<Floor>;
	var residueCount:Int;
	var residueTypes:Vector<Int>; // uint16 [64] varies
	var residueConfig:Vector<Residue>; 
	var mappingCount:Int;
	var mapping:Vector<Mapping>;
	var modeConfig:Vector<Mode>; // [64] varies
	
	// decode buffer
	var channelBuffers:Vector<Vector<Float>>; //var *[STB_VORBIS_MAX_CHANNELS];
	
	var previousWindow:Vector<Vector<Float>>; //var *[STB_VORBIS_MAX_CHANNELS];
	var previousLength:Int;
	var finalY:Vector<Vector<Int>>; // [STB_VORBIS_MAX_CHANNELS];

	var currentLoc:Int; //uint32  sample location of next frame to decode
	var currentLocValid:Int;

	// per-blocksize precomputed data

	// twiddle factors
	var a:Vector<Vector<Float>>; // var *  [2]
	var b:Vector<Vector<Float>>; // var *  [2]
	var c:Vector<Vector<Float>>; // var *  [2]
	var window:Vector<Vector<Float>>; //var * [2]; 
	var bitReverseData:Vector<Vector<Int>>; //uint16 * [2]

	// current page/packet/segment streaming info
	var lastPage:Int;
	var segments:Bytes;	  // uint8 [255];
	var pageFlag:Int;	 // uint8 
	var bytesInSeg:Int; // uint8 
	var firstDecode:Bool = false; // uint8 
	var nextSeg:Int = 0;
	var lastSeg:Bool;  // flag that we're on the last segment
	var lastSegWhich:Int; // what was the segment number of the last seg?
	var acc:UInt;
	var validBits:Int = 0;
	var packetBytes:Int;
	var endSegWithKnownLoc:Int;
	var knownLocForPacket:Int;
	var discardSamplesDeferred:Int;
	
	// push mode scanning
	//var pageCrcTests:Int; // only in pushMode: number of tests active; -1 if not searching

	// sample-access
	var channelBufferStart:Int; 
	var channelBufferEnd:Int;
	var error:VorbisError;
	
	var longestFloorlist = 0;
	//var maxSubmaps = 0;
	
	public function new (i:Input) {
		stream = i;
	}
	
	public function readAll(output:Output, useFloat:Bool = false) {
		open();
		var count = 0;
		while (true) {
			var time = Date.now().getTime();
			var n = getSamplesFloatInterleaved(output, 4096 * 64, useFloat);
			if (n == 0) {
				break;
			}
			
			count += n;
			Sys.println(count + ":" + (Date.now().getTime() - time));
		}
		return count;
	}
	
	public function read(output:Output, useFloat:Bool = false) 
	{
		var n = getSamplesFloatInterleaved(output, 4096, useFloat);
		return n;
	}
	
	function getSamplesFloatInterleaved(output:Output, len:Int, useFloat:Bool) {
		var n = 0;
		
		while (n < len) {
			var k = channelBufferEnd - channelBufferStart;
			if (n + k >= len) k = len - n;
			if (useFloat) {
				for (j in 0...k) {
					for (i in 0...channels) {
						var value = channelBuffers[i][channelBufferStart + j];
						if (value > 1) {
							value = 1;
						} else if (value < -1) {
							value = -1;
						}
						output.writeFloat(value);
					}
				}
			} else {
				for (j in 0...k) {
					for (i in 0...channels) {
						var value = channelBuffers[i][channelBufferStart + j];
						if (value > 1) {
							value = 1;
						} else if (value < -1) {
							value = -1;
						}
						output.writeInt16(Math.floor(value * 0x7FFF));
					}
				}
			}
			
			n += k;
			channelBufferStart += k;
			if (n == len) {
				break;
			}
			
			var frameLen = getFrameFloat();
			if (frameLen == 0) {
				break;
			}
		}
		return n;
	}
	
	function getFrameFloat()
	{
		var result = decodePacket();
		if (result == null) {
			channelBufferStart = channelBufferEnd = 0;
			return 0;
		}

		var len = finishFrame(result);
		
		channelBufferStart = result.left;
		channelBufferEnd = result.left + len;
		return len;
	}
	
	//読み込みの準備を行う。
	public function open() {
		startDecoder();
		pumpFirstFrame();
	}
	
	
	function pumpFirstFrame() {
		finishFrame(decodePacket());
	}
	
	function finishFrame(r:DecodePacketResult):Int {
		var len = r.len;
		var right = r.right;
		var left = r.left;
		
		// we use right&left (the start of the right- and left-window sin()-regions)
		// to determine how much to return, rather than inferring from the rules
		// (same result, clearer code); 'left' indicates where our sin() window
		// starts, therefore where the previous window's right edge starts, and
		// therefore where to start mixing from the previous buffer. 'right'
		// indicates where our sin() ending-window starts, therefore that's where
		// we start saving, and where our returned-data ends.

		// mixin from previous window
		if (previousLength != 0) {
			var n = previousLength;
			var w = getWindow(n);
			for (i in 0...channels) {
				var cb = channelBuffers[i];
				var pw = previousWindow[i];
				for (j in 0...n) {
					cb[left+j] = cb[left+j] * w[j] + pw[j] * w[n-1-j];
				}
			}
		}
		
		var prev = previousLength;

		// last half of this data becomes previous window
		previousLength = len - right;

		// @OPTIMIZE: could avoid this copy by double-buffering the
		// output (flipping previousWindow with channelBuffers), but
		// then previousWindow would have to be 2x as large, and
		// channelBuffers couldn't be temp mem (although they're NOT
		// currently temp mem, they could be (unless we want to level
		// performance by spreading out the computation))
		for (i in 0...channels) {
			var pw = previousWindow[i];
			var cb = channelBuffers[i];
			for (j in 0...(len - right)) {
				pw[j] = cb[right + j];
			}
		}
		
		if (prev == 0) {
			// there was no previous packet, so this data isn't valid...
			// this isn't entirely true, only the would-have-overlapped data
			// isn't valid, but this seems to be what the spec requires
			return 0;
		}
		
		// truncate a short frame
		if (len < right) {
			right = len;
		}

		return right - left;
	}
	
	function getWindow(len:Int) 
	{
		len <<= 1;
		return if (len == blocksize0) {
			window[0];
		} else if (len == blocksize1) {
			window[1];
		} else {
			assert(false);
			null;
		}
	}
	
	function decodePacket():DecodePacketResult
	{
		var result = decodeInitial();
		if (result == null) {
			return null;
		}
		var rest = decodePacketRest(result);
		return rest;
	}
	
	function decodePacketRest(r:DecodeInitialResult):DecodePacketResult
	{
		var len = 0;
		var m:Mode = modeConfig[r.mode];
		
		var zeroChannel = new Vector<Bool>(256);
		var reallyZeroChannel = new Vector<Bool>(256);

		// WINDOWING
		
		var n = m.blockflag ? blocksize1 : blocksize0;
		var map = mapping[m.mapping];
		
		// FLOORS
		var n2 = n >> 1;
		stbProf(1);
		var rangeList = [256, 128, 86, 64];
		
		for (i in 0...channels) {
			var s = map.chan[i].mux;
			zeroChannel[i] = false;
			var floor = map.submapFloor[s];
			if (floorTypes[floor] == 0) {
				throw new VorbisError(INVALID_STREAM);
			} else {
				var g:Floor1 = floorConfig[floor].floor1;
				if (readBits(1) != 0) {
					var fy = new Vector<Int>(g.values);
					var step2Flag = new Vector<Bool>(256);
					var range = rangeList[g.floor1Multiplier-1];
					var offset = 2;
					fy = finalY[i];
					fy[0] = readBits(MathTools.ilog(range)-1);
					fy[1] = readBits(MathTools.ilog(range)-1);
					for (j in 0...g.partitions) {
						var pclass = g.partitionClassList[j];
						var cdim = g.classDimensions[pclass];
						var cbits = g.classSubclasses[pclass];
						var csub = (1 << cbits) - 1;
						var cval = 0;
						if (cbits != 0) {
							var c = codebooks[g.classMasterbooks[pclass]];
							cval = decode(c);
						}
						for (k in 0...cdim) {
							var book = g.subclassBooks[pclass][cval & csub];
							cval = cval >> cbits;
							if (book >= 0) {
								var c:Codebook = codebooks[book];
								fy[offset++] = decode(c);
							} else {
								fy[offset++] = 0;
							}
						}
					}
					
					if (validBits == INVALID_BITS) {
						zeroChannel[i] = true;
						continue;
					}
					
					step2Flag[0] = step2Flag[1] = true;
					for (j in 2...g.values) {
						var low = g.neighbors[j][0];
						var high = g.neighbors[j][1];
						//neighbors(g.xlist, j, &low, &high);
						var pred = predictPoint(g.xlist[j], g.xlist[low], g.xlist[high], fy[low], fy[high]);
						var val = fy[j];
						var highroom = range - pred;
						var lowroom = pred;
						var room = if (highroom < lowroom){
							highroom * 2;
						}else{
							lowroom * 2;
						}
						if (val != 0) {
							step2Flag[low] = step2Flag[high] = true;
							step2Flag[j] = true;
							if (val >= room){
								if (highroom > lowroom){
									fy[j] = val - lowroom + pred;
								}else{
									fy[j] = pred - val + highroom - 1;
								}
							} else {
								if (val & 1 != 0){
									fy[j] = pred - ((val+1)>>1);
								} else{
									fy[j] = pred + (val>>1);
								} 
							}
						} else {
							step2Flag[j] = false;
							fy[j] = pred;
						}
					}
					
					// defer final floor computation until _after_ residue
					for (j in 0...g.values) {
						if (!step2Flag[j]){
							fy[j] = -1;
						}
					}
					
				} else {
					zeroChannel[i] = true;
				}
				// So we just defer everything else to later
				// at this point we've decoded the floor into buffer
			}
		}
		stbProf(0);
		// at this point we've decoded all floors

		//if (alloc.allocBuffer) {
		//	assert(alloc.allocBufferLengthInBytes == tempOffset);
		//}
		
		// re-enable coupled channels if necessary
		for (i in 0...channels) {
			reallyZeroChannel[i] = zeroChannel[i];
		}
		for (i in 0...map.couplingSteps) {
			if (!zeroChannel[map.chan[i].magnitude] || !zeroChannel[map.chan[i].angle]) {
				zeroChannel[map.chan[i].magnitude] = zeroChannel[map.chan[i].angle] = false;
			}
		}
		// RESIDUE DECODE
		for (i in 0...map.submaps) {
			var residueBuffers = new Vector<Vector<Float>>(channels);
			var doNotDecode = new Vector<Bool>(256);
			var ch = 0;
			for (j in 0...channels) {
				if (map.chan[j].mux == i) {
					if (zeroChannel[j]) {
						doNotDecode[ch] = true;
						residueBuffers[ch] = null;
					} else {
						doNotDecode[ch] = false;
						residueBuffers[ch] = channelBuffers[j];
					}
					++ch;
				}
			}
			
			var r = map.submapResidue[i];
			decodeResidue(residueBuffers, ch, n2, r, doNotDecode);
		}
		
		// INVERSE COUPLING
		stbProf(14);
		
		var i = map.couplingSteps;
		var n2 = n >> 1;
		while (--i >= 0) {
			var m = channelBuffers[map.chan[i].magnitude];
			var a = channelBuffers[map.chan[i].angle];
			for (j in 0...n2) {
				var a2, m2;
				if (m[j] > 0) {
					if (a[j] > 0) {
						m2 = m[j];
						a2 = m[j] - a[j];
					} else {
						a2 = m[j];
						m2 = m[j] + a[j];
					}
				} else {
					if (a[j] > 0) {
						m2 = m[j]; 
						a2 = m[j] + a[j];
					} else {
						a2 = m[j];
						m2 = m[j] - a[j];
					}
				}
				m[j] = m2;
				a[j] = a2;
			}
		}

		// finish decoding the floors
		stbProf(15);
		for (i in 0...channels) {
			if (reallyZeroChannel[i]) {
				for(j in 0...n2) {
					channelBuffers[i][j] = 0;
				}
			} else {
				doFloor(map, i, n, channelBuffers[i], finalY[i], null);
			}
		}

		// INVERSE MDCT
		stbProf(16);
		for (i in 0...channels) {
			inverseMdct(channelBuffers[i], n, m.blockflag);
		}
		stbProf(0);

		// this shouldn't be necessary, unless we exited on an error
		// and want to flush to get to the next packet
		flushPacket();

		var left = r.left.start;
		var currentLocValid = false;
		if (firstDecode) {
			// assume we start so first non-discarded sample is sample 0
			// this isn't to spec, but spec would require us to read ahead
			// and decode the size of all current frames--could be done,
			// but presumably it's not a commonly used feature
			currentLoc = -n2; // start of first frame is positioned for discard
			// we might have to discard samples "from" the next frame too,
			// if we're lapping a large block then a small at the start?
			discardSamplesDeferred = n - r.right.end;
			currentLocValid = true;
			firstDecode = false;
		} else if (discardSamplesDeferred != 0) {
			r.left.start += discardSamplesDeferred;
			left = r.left.start;
			discardSamplesDeferred = 0;
		} else if (previousLength == 0 && currentLocValid) {
			// we're recovering from a seek... that means we're going to discard
			// the samples from this packet even though we know our position from
			// the last page header, so we need to update the position based on
			// the discarded samples here
			// but wait, the code below is going to add this in itself even
			// on a discard, so we don't need to do it here...
		}
	
		// check if we have ogg information about the sample # for this packet
		if (lastSegWhich == endSegWithKnownLoc) {
			// if we have a valid current loc, and this is final:
			if (currentLocValid && (pageFlag & VorbisPageFlag.LAST_PAGE) != 0) {
				var currentEnd = knownLocForPacket - (n - r.right.end);
				// then let's infer the size of the (probably) short final frame
				if (currentEnd < currentLoc + r.right.end) {
					if (currentEnd < currentLoc) {
						// negative truncation, that's impossible!
						len = 0;
					} else {
						len = currentEnd - currentLoc;
					}
					len += r.left.start;
					currentLoc += len;
					
					return {
						len : len,
						left : left,
						right : r.right.start,
					}
				}
			}
			// otherwise, just set our sample loc
			// guess that the ogg granule pos refers to the Middle_ of the
			// last frame?
			// set currentLoc to the position of leftStart
			currentLoc = knownLocForPacket - (n2-r.left.start);
			currentLocValid = true;
		}
		
		if (currentLocValid) {
			currentLoc += (r.right.start - r.left.start);
		}
		
		//if (alloc.allocBuffer)
		//	assert(alloc.allocBufferLengthInBytes == tempOffset);
		
		return {
			len : r.right.end,
			left : left,
			right : r.right.start,
		}
	}
	
	function doFloor(map:Mapping, i:Int, n:Int, target:Vector<Float>, finalY:Vector<Int>, step2Flag:Vector<Bool>) 
	{
		var n2 = n >> 1;
		var s = map.chan[i].mux, floor;
		var floor = map.submapFloor[s];
		if (floorTypes[floor] == 0) {
			throw new VorbisError(INVALID_STREAM);
		} else {
			var g = floorConfig[floor].floor1;
			var lx = 0, ly = finalY[0] * g.floor1Multiplier;
			for (q in 1...g.values) {
				var j = g.sortedOrder[q];
				if (finalY[j] >= 0)
				{
					var hy = finalY[j] * g.floor1Multiplier;
					var hx = g.xlist[j];
					drawLine(target, lx, ly, hx, hy, n2);
					lx = hx;
					ly = hy;
				}
			}
			if (lx < n2) {
				// optimization of: drawLine(target, lx,ly, n,ly, n2);
				for (j in lx...n2) {
					target[j] *= VorbisSetting.INVERSE_DB_TABLE[ly];
				}
			}
		}
	}
	
	function drawLine(output:Vector<Float>, x0:Int, y0:Int, x1:Int, y1:Int, n:Int) 
	{
		var dy = y1 - y0;
		var adx = x1 - x0;
		var ady = dy < 0 ? -dy : dy;
		var base:Int;
		var x = x0;
		var y = y0;
		var err = 0;
		var sy = if (adx < DIVTAB_DENOM && ady < DIVTAB_NUMER) {
			if (dy < 0) {
				base = -integerDivideTable[ady][adx];
				base - 1;
			} else {
				base = integerDivideTable[ady][adx];
				base + 1;
			}
		} else {
			base = Std.int(dy / adx);
			if (dy < 0) {
				base - 1;
			} else {
				base + 1;
			}
		}
		ady -= (base < 0 ? -base : base) * adx;
		if (x1 > n) {
			x1 = n;
		}
		
		output[x] *= VorbisSetting.INVERSE_DB_TABLE[y];
		
		for (i in (x + 1)...x1) {
			err += ady;
			if (err >= adx) {
				err -= adx;
				y += sy;
			} else {
				y += base;
			}
			output[i] *= VorbisSetting.INVERSE_DB_TABLE[y];
		}
	}
	
	function inverseMdct(buffer:Vector<Float>, n:Int, blocktype:Bool) {
		var bt = blocktype ? 1 : 0;
		Mdct.inverseTransform(buffer, n, a[bt], b[bt], c[bt], bitReverseData[bt]);
	}
	
	function decodeResidue(residueBuffers:Vector<Vector<Float>>, ch:Int, n:Int, rn:Int,  doNotDecode:Vector<Bool>) 
	{
		//STB_VORBIS_DIVIDES_IN_RESIDUE = true
		var r:Residue = residueConfig[rn];
		var rtype = residueTypes[rn];
		var c = r.classbook;
		var classwords = codebooks[c].dimensions;
		var nRead = r.end - r.begin;
		var partRead = Std.int(nRead / r.partSize);
		//var temp_alloc_point = temp_allocSave(f);
		var classifications = blockArray(channels, partRead);
		
		stbProf(2);
		for (i in 0...ch) {
			if (!doNotDecode[i]) {
				var buffer = residueBuffers[i];
				for (j in 0...buffer.length) {
					buffer[j] = 0;
				}
			}
		}
		
		if (rtype == 2 && ch != 1) {
			for (j in 0...ch) {
				if (!doNotDecode[j]) {
					break;
				} else if (j == ch - 1) {
					return;
				}
			}

			stbProf(3);
			for (pass in 0...8) {
				var pcount = 0, classSet = 0;
				if (ch == 2) {
					stbProf(13);
					while (pcount < partRead) {
						var z = r.begin + pcount*r.partSize;
						var cInter = (z & 1);
						var pInter = z >> 1;
						if (pass == 0) {
							var c:Codebook = codebooks[r.classbook];
							var q = decode(c);
							if (q == EOP) {
								return;
							}
							
							var i = classwords;
							while (--i >= 0) {
								classifications[0][i+pcount] = q % r.classifications;
								q = Std.int(q / r.classifications);
							}
						}
						stbProf(5);
						for (i in 0...classwords) {
							if (pcount >= partRead) {
								break;
							}
							var z = r.begin + pcount*r.partSize;
							var c = classifications[0][pcount];
							var b = r.residueBooks[c][pass];
							if (b >= 0) {
								var book = codebooks[b];
								stbProf(20);  // accounts for X time
								var result = codebookDecodeDeinterleaveRepeat(book, residueBuffers, ch, cInter, pInter, n, r.partSize);
								if (result == null) {
									return;
								} else {
									cInter = result.cInter;
									pInter = result.pInter;
								}
								stbProf(7);
							} else {
								z += r.partSize;
								cInter = z & 1;
								pInter = z >> 1;
							}
							++pcount;
						}
						stbProf(8);
					}
				} else if (ch == 1) {
					while (pcount < partRead) {
						var z = r.begin + pcount*r.partSize;
						var cInter = 0;
						var pInter = z;
						if (pass == 0) {
							var c:Codebook = codebooks[r.classbook];
							var q = decode(c);
							if (q == EOP) return;
							
							var i = classwords;
							while (--i >= 0) {
								classifications[0][i + pcount] = q % r.classifications;
								q = Std.int(q / r.classifications);
							}
						}
						
						for (i in 0...classwords) {
							if (pcount >= partRead) {
								break;
							}
							var z = r.begin + pcount * r.partSize;
							var c = classifications[0][pcount];
							var b = r.residueBooks[c][pass];
							if (b >= 0) {
								var book:Codebook = codebooks[b];
								stbProf(22);
								var result = codebookDecodeDeinterleaveRepeat(book, residueBuffers, ch, cInter, pInter, n, r.partSize);
								if (result == null) {
									return;
								} else {
									cInter = result.cInter;
									pInter = result.pInter;
								}
								stbProf(3);
							} else {
								z += r.partSize;
								cInter = 0;
								pInter = z;
							}
							++pcount;
						}
					}
				} else {
					while (pcount < partRead) {
						var z = r.begin + pcount * r.partSize;
						var cInter = z % ch;
						var pInter = Std.int(z / ch);
						if (pass == 0) {
							var c:Codebook = codebooks[r.classbook];
							var q = decode(c);
							if (q == EOP) {
								return;
							}
							
							var i = classwords;
							while (--i >= 0) {
								classifications[0][i+pcount] = q % r.classifications;
								q = Std.int(q / r.classifications);
							}
						}
						
						for (i in 0...classwords) {
							if (pcount >= partRead) {
								break;
							}
							var z = r.begin + pcount*r.partSize;
							var c = classifications[0][pcount];
					
							var b = r.residueBooks[c][pass];
							if (b >= 0) {
								var book = codebooks[b];
								stbProf(22);
								var result = codebookDecodeDeinterleaveRepeat(book, residueBuffers, ch, cInter, pInter, n, r.partSize);
								if (result == null) {
									return;
								} else {
									cInter = result.cInter;
									pInter = result.pInter;
								}
								stbProf(3);
							} else {
								z += r.partSize;
								cInter = z % ch;
								pInter = Std.int(z / ch);
							}
							++pcount;
						}
					}
				}
			}
			return;
		}
		stbProf(9);

		for (pass in 0...8) {
			var pcount = 0;
			var classSet = 0;
			while (pcount < partRead) {
				if (pass == 0) {
					for (j in 0...ch) {
						if (!doNotDecode[j]) {
							var c:Codebook = codebooks[r.classbook];
							var temp = decode(c);
							if (temp == EOP) {
								return;
							}
							var i = classwords;
							while (--i >= 0) {
								classifications[j][i+pcount] = temp % r.classifications;
								temp = Std.int(temp / r.classifications);
							}
						}
					}
				}
				for (i in 0...classwords) {
					if (pcount >= partRead) {
						break;
					}
					for (j in 0...ch) {
						if (!doNotDecode[j]) {
							var c = classifications[j][pcount];
							var b = r.residueBooks[c][pass];
							if (b >= 0) {
								var target = residueBuffers[j];
								var offset = r.begin + pcount * r.partSize;
								var n = r.partSize;
								var book = codebooks[b];
								if (!residueDecode(book, target, offset, n, rtype)) {
									return;
								}
							}
						}
					}
					++pcount;
				}
			}
		}
	}
	
	function residueDecode(book:Codebook, target:Vector<Float>, offset:Int, n:Int, rtype:Int) 
	{
		if (rtype == 0) {
			var step = Std.int(n / book.dimensions);
			for (k in 0...step) {
				if (!codebookDecodeStep(book, target, offset + k, n-offset-k, step)) {
					return false;
				}
			}
		} else {
			var k = 0;
			while(k < n) {
				if (!codebookDecode(book, target, offset, n-k)) {
					return false;
				}
				k += book.dimensions;
				offset += book.dimensions;
			}
		}
		return true;
	}
	
	function codebookDecode(c:Codebook, output:Vector<Float>, offset:Int, len:Int) 
	{
		var z = codebookDecodeStart(c);
		
		if (z < 0) {
			return false;
		}
		if (len > c.dimensions) {
			len = c.dimensions;
		}
			
		// STB_VORBIS_DIVIDES_IN_CODEBOOK = true
		if (c.lookupType == 1) {
			var div = 1;
			var last = codebookElementBase(c);
			for (i in 0...len) {
				var off = Std.int(z / div) % c.lookupValues;
				var val = codebookElementFast(c,off) + last;
				output[offset + i] += val;
				if (c.sequenceP) {
					last = val + c.minimumValue;
				}
				div *= c.lookupValues;
			}
			return true;
		} 
		
		z *= c.dimensions;
		if (c.sequenceP) {
			var last = codebookElementBase(c);
			for (i in 0...len) {
				var val = codebookElementFast(c,z+i) + last;
				output[offset + i] += val;
				last = val + c.minimumValue;
			}
		} else {
			var last = codebookElementBase(c);
			for (i in 0...len) {
				output[offset + i] += codebookElementFast(c,z+i) + last;
			}
		}
		return true;
	}
	
	function codebookDecodeStep(c:Codebook, output:Vector<Float>, offset:Int, len:Int, step:Int) 
	{
		var z = codebookDecodeStart(c);
		var last = codebookElementBase(c);
		if (z < 0) {
			return false;
		}
		if (len > c.dimensions) {
			len = c.dimensions;
		}

		// STB_VORBIS_DIVIDES_IN_CODEBOOK = true
		if (c.lookupType == 1) {
			var div = 1;
			for (i in 0...len) {
				var off = Std.int(z / div) % c.lookupValues;
				var val = codebookElementFast(c,off) + last;
				output[offset + i * step] += val;
				if (c.sequenceP) {
					last = val;
				}
				div *= c.lookupValues;
			}
			return true;
		}
		
		z *= c.dimensions;
		for (i in 0...len) {
			var val = codebookElementFast(c,z+i) + last;
			output[offset + i * step] += val;
			if (c.sequenceP) {
				last = val;
			}
		}
		
		return true;
	}
	
	function codebookDecodeStart(c:Codebook) 
	{
		var z = -1;
		// type 0 is only legal in a scalar context
		if (c.lookupType == 0) {
			throw new VorbisError(INVALID_STREAM);
		} else {
			z = decodeVq(c);
			if (c.sparse) assert(z < c.sortedEntries);
			if (z < 0) {  // check for EOP
				if (bytesInSeg == 0) {
					if (lastSeg) {
						return z;
					}
				}
				throw new VorbisError(INVALID_STREAM);
			}
		}
		
		return z;
	}
	
	function codebookDecodeDeinterleaveRepeat(c:Codebook, residueBuffers:Vector<Vector<Float>>, ch:Int, cInter:Int, pInter:Int, len:Int, totalDecode:Int) 
	{
		var effective = c.dimensions;

		// type 0 is only legal in a scalar context
		if (c.lookupType == 0) {
			throw new VorbisError(INVALID_STREAM);
		}

		while (totalDecode > 0) {
			var last = codebookElementBase(c);
			var z = decodeVq(c);
			
			if (z < 0) {
				if (bytesInSeg == 0) {
					if (lastSeg) {
						return null;
					}
				}
				throw new VorbisError(INVALID_STREAM);
			}

			// if this will take us off the end of the buffers, stop short!
			// we check by computing the length of the virtual interleaved
			// buffer (len*ch), our current offset within it (pInter*ch)+(cInter),
			// and the length we'll be using (effective)
			if (cInter + pInter * ch + effective > len * ch) {
				effective = len * ch - (pInter * ch - cInter);
			}
			
			if (c.lookupType == 1) {
				var div = 1;
				for (i in 0...effective) {
					var off = Std.int(z / div) % c.lookupValues;
					var val = codebookElementFast(c, off) + last;
					if (residueBuffers[cInter] != null) {
						residueBuffers[cInter][pInter] += val;
					}
					if (++cInter == ch) { 
						cInter = 0; 
						++pInter; 
					}
					
					if (c.sequenceP) {
						last = val;
					}
					div *= c.lookupValues;
				}
			} else {
				z *= c.dimensions;
				if (c.sequenceP) {
					for (i in 0...effective) {
						var val = codebookElementFast(c,z+i) + last;
						if (residueBuffers[cInter] != null) {
							residueBuffers[cInter][pInter] += val;
						}
						if (++cInter == ch) { 
							cInter = 0; 
							++pInter; 
						}
						last = val;
					}
				} else {
					
					for (i in 0...effective) {
						var val = codebookElementFast(c,z+i) + last;
						if (residueBuffers[cInter] != null) {
							residueBuffers[cInter][pInter] += val;
						}
						if (++cInter == ch) { 
							cInter = 0; 
							++pInter; 
						}
					}
				}
			}

			totalDecode -= effective;
		}
		
		return {
			cInter : cInter,
			pInter : pInter
		}
	}
	
	// STB_VORBIS_CODEBOOK_FLOATS = true;
	inline function codebookElement(c:Codebook, off:Int) {
		return c.multiplicands[off];
	}
	
	inline function codebookElementFast(c:Codebook, off:Int) {
		return c.multiplicands[off];
	}
	
	inline function codebookElementBase(c:Codebook) {
		return 0.0;
	}
	
	inline function stbProf(i:Int) 
	{
		//empty
	}
	
	inline function blockArray(channels:Int, size:Int) 
	{
		var vector = new Vector<Vector<Int>>(channels);
		for (i in 0...channels) {
			vector[i] = new Vector(size);
		}
		return vector;
	}
	
	inline function predictPoint(x:Int, x0:Int,  x1:Int,  y0:Int, y1:Int):Int 
	{
		var dy = y1 - y0;
		var adx = x1 - x0;
		// @OPTIMIZE: force int division to round in the right direction... is this necessary on x86?
		var err = Math.abs(dy) * (x - x0);
		var off = Std.int(err / adx);
		return dy < 0 ? (y0 - off) : (y0 + off);
	}
	
	function decodeInitial():DecodeInitialResult
	{
		channelBufferStart = channelBufferEnd = 0;
		
		do {
			if (eof || !maybeStartPacket()) {
				return null;
			}
			
			// check packet type
			if (readBits(1) != 0) {
				while (EOP != readPacket()) {};
				continue;
			}
			break;
		} while (true);
		
		var i = readBits(MathTools.ilog(modeConfig.length - 1));
		if (i == EOP || i >= modeConfig.length) {
			throw new VorbisError(VorbisErrorType.SEEK_FAILED);
		}
		
		var m = modeConfig[i];
		var n, prev, next;
		
		if (m.blockflag) {
			n = blocksize1;
			prev = readBits(1);
			next = readBits(1);
		} else {
			prev = next = 0;
			n = blocksize0;
		}

		// WINDOWING
		var windowCenter = n >> 1;
		
		return {
			mode : i,
			left : if (m.blockflag && prev == 0) {
				start : (n - blocksize0) >> 2,
				end : (n + blocksize0) >> 2,
			} else {
				start : 0,
				end : windowCenter,
			},
			right : if (m.blockflag && next == 0) {
				start : (n * 3 - blocksize0) >> 2,
				end : (n * 3 + blocksize0) >> 2,
			} else {
				start : windowCenter,
				end : n,
			},
		}
	}
	
	function startDecoder() {
		longestFloorlist = 0;
		
		startPage();
		if ((pageFlag & VorbisPageFlag.FIRST_PAGE) == 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "not firstPage");
		}
		if ((pageFlag & VorbisPageFlag.LAST_PAGE) != 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "lastPage");
		}
		if ((pageFlag & VorbisPageFlag.CONTINUED_PACKET) != 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "continuedPacket");
		}
		if (segments.length != 1) {
			throw new VorbisError(INVALID_FIRST_PAGE, "segmentCount");
		}
		if (segments.get(0) != 30) {
			throw new VorbisError(INVALID_FIRST_PAGE, "segment head");
		}
		if (stream.readByte() != VorbisPacket.ID) {
			throw new VorbisError(INVALID_FIRST_PAGE, "segment head");
		}
		
		var header = stream.read(6);
		
		// vorbisVersion
		var version = stream.readInt32();
		if (version != 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "vorbis version : " + version);
		}
		
		channels = stream.readByte();
		if (channels == 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "no channel");
		} else if (channels > VorbisSetting.MAX_CHANNELS) {
			throw new VorbisError(TOO_MANY_CHANNELS, "too many channels");
		}
		
		sampleRate = stream.readInt32();
		if (sampleRate == 0) {
			throw new VorbisError(INVALID_FIRST_PAGE, "no sampling rate");
		}
		
		stream.readInt32(); // bitrateMaximum
		stream.readInt32(); // bitrateNominal
		stream.readInt32(); // bitrateMinimum
		
		var x = stream.readByte();
		var log0 = x & 15;
		var log1 = x >> 4;
		blocksize0 = 1 << log0; 
		blocksize1 = 1 << log1;
		if (log0 < 6 || log0 > 13) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (log1 < 6 || log1 > 13) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (log0 > log1) {
			throw new VorbisError(INVALID_SETUP);
		}
		
		// framingFlag
		var x = stream.readByte();
		if (x & 1 == 0) {
			throw new VorbisError(INVALID_FIRST_PAGE);
		}
		
		// second packet!
		startPage();
		startPacket();
		
		var len:Int = 0;
		do {
			len = nextSegment();
			skip(len);
			bytesInSeg = 0;
		} while (len != 0);
		
		// third packet!
		startPacket();
		
		//crc32Init();
		if (readPacket() != VorbisPacket.SETUP) {
			throw new VorbisError(VorbisErrorType.INVALID_SETUP, "setup packet");
		}
		
		for (i in 0...6) {
			header.set(i, readPacket());
		}
		
		if (!vorbisValidate(header)) {
			throw new VorbisError(VorbisErrorType.INVALID_SETUP, "vorbis header");
		}
		
		// codebooks
		var codebookCount = readBits(8) + 1;
		codebooks = new Vector(codebookCount);
		for (i in 0...codebookCount) {
			codebooks[i] = readCodebook();
		}
		
		// time domain transfers (notused)
		x = readBits(6) + 1;
		for (i in 0...x) {
			var z:UInt = readBits(16);
			if (z != 0) throw new VorbisError(INVALID_SETUP);
		}
		
		// Floors
		var floorCount = readBits(6)+1;
		floorConfig = new Vector(floorCount);
		floorTypes = new Vector(64);
		for (i in 0...floorCount) {
			floorConfig[i] = readFloor(i);
		}
		
		// Residue
		var residueCount = readBits(6) + 1;
		residueConfig = new Vector(residueCount);
		residueTypes = new Vector(64);
		for (i in 0...residueCount) {
			residueConfig[i] = readResidue(i);
		}
		
		//Mapping
		var mappingCount = readBits(6) + 1;
		mapping = new Vector(mappingCount);
		for (i in 0...mappingCount) {
			mapping[i] = readMapping();
		}
		
		var modeCount = readBits(6) + 1;
		modeConfig = new Vector(modeCount);
		for (i in 0...modeCount) {
			modeConfig[i] = readMode();
		}
		
		flushPacket();
		
		//Channel
		previousLength = 0;
		
		channelBuffers = new Vector(channels);
		previousWindow = new Vector(channels);
		finalY = new Vector(channels);
		
		for (i in 0...channels) {
			channelBuffers[i] = emptyFloatVector(blocksize1);
			previousWindow[i] = emptyFloatVector(Std.int(blocksize1 / 2));
			finalY[i] = new Vector(longestFloorlist);
		}
		
		a = new Vector(2);
		b = new Vector(2);
		c = new Vector(2);
		window = new Vector(2);
		bitReverseData = new Vector(2);
		initBlocksize(0, blocksize0);
		initBlocksize(1, blocksize1);
		
		//blocksize[0] = blocksize0;
		//blocksize[1] = blocksize1;
		
		if (integerDivideTable == null) {
			integerDivideTable = new Vector(DIVTAB_NUMER);
			for (i in 0...DIVTAB_NUMER) {
				integerDivideTable[i] = new Vector(DIVTAB_DENOM);
				for (j in 1...DIVTAB_DENOM) {
					integerDivideTable[i][j] = Std.int(i / j);
				}
			}
		}
		
		firstDecode = true;
		//firstAudioPageOffset = vorbisGetFileOffset();
	}
	
	function emptyFloatVector(len:Int) 
	{
		var vec = new Vector<Float>(len);
		for (i in 0...len) {
			vec[i] = 0;
		}
		return vec;
	}
	
	function initBlocksize(bs:Int, n:Int) 
	{
		var n2 = n >> 1, n4 = n >> 2, n8 = n >> 3;
		a[bs] = new Vector(n2);
		b[bs] = new Vector(n2);
		c[bs] = new Vector(n4);
		
		computeTwiddleFactors(n, a[bs], b[bs], c[bs]);
		window[bs] = new Vector(n2);
		computeWindow(n, window[bs]);
		bitReverseData[bs] = new Vector(n8);
		computeBitReverse(n, bitReverseData[bs]);
	}
	
	function computeTwiddleFactors(n:Int, af:Vector<Float>, bf:Vector<Float>, cf:Vector<Float>)
	{
		var n4 = n >> 2;
		var n8 = n >> 3;

		var k2 = 0;
		for (k in 0...n4) {
			af[k2] = Math.cos(4*k*M_PI/n);
			af[k2 + 1] = -Math.sin(4*k*M_PI/n);
			bf[k2] = Math.cos((k2+1)*M_PI/n/2) * 0.5;
			bf[k2 + 1] = Math.sin((k2 + 1) * M_PI / n / 2) * 0.5;
			k2 += 2;
		}

		var k2 = 0;
		for (k in 0...n8) {
			cf[k2  ] = Math.cos(2*(k2+1) * M_PI/n);
			cf[k2+1] = -Math.sin(2*(k2+1) * M_PI/n);
			k2 += 2;
		}
	}

	function computeWindow(n:Int, window:Vector<Float>)
	{
		var n2 = n >> 1;
		for (i in 0...n2) {
			window[i] = Math.sin(0.5 * M_PI * square(Math.sin((i - 0 + 0.5) / n2 * 0.5 * M_PI)));
		}
	}
	
	function square(f:Float) {
		return f * f;
	}
	
	function computeBitReverse(n:Int, rev:Vector<Int>)
	{
		var ld = MathTools.ilog(n) - 1; 
		var n8 = n >> 3;
		
		for (i in 0...n8) {
		  rev[i] = (bitReverse(i) >>> (32 - ld + 3)) << 2;
		}
	}
	
	function readMode() 
	{
		var m = new Mode();
		m.blockflag = (readBits(1) != 0);
		m.windowtype = readBits(16);
		m.transformtype = readBits(16);
		m.mapping = readBits(8);
		if (m.windowtype != 0) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (m.transformtype != 0) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (m.mapping >= mapping.length) {
			throw new VorbisError(INVALID_SETUP);
		}
		return m;
	}
	
	function readMapping():Mapping
	{
		var m = new Mapping();
		var mappingType = readBits(16);
		if (mappingType != 0) {
			throw new VorbisError(INVALID_SETUP, "mapping type " + mappingType);
		}
		
		m.chan = new Vector(channels);
		for (j in 0...channels) {
			m.chan[j] = new MappingChannel();
		}
		
		if (readBits(1) != 0) {
			m.submaps = readBits(4)+1;
		} else {
			m.submaps = 1;
		}
		
		//if (m.submaps > maxSubmaps) {
		//	maxSubmaps = m.submaps;
		//}
		
		if (readBits(1) != 0) {
			m.couplingSteps = readBits(8)+1;
			for (k in 0...m.couplingSteps) {
				m.chan[k].magnitude = readBits(MathTools.ilog(channels-1));
				m.chan[k].angle = readBits(MathTools.ilog(channels-1));
				if (m.chan[k].magnitude >= channels) {
					throw new VorbisError(INVALID_SETUP);
				}
				if (m.chan[k].angle >= channels) {
					throw new VorbisError(INVALID_SETUP);
				}
				if (m.chan[k].magnitude == m.chan[k].angle) {
					throw new VorbisError(INVALID_SETUP);
				}
			}
		} else {
			m.couplingSteps = 0;
		}

		// reserved field
		if (readBits(2) != 0) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (m.submaps > 1) {
			for (j in 0...channels) {
				m.chan[j].mux = readBits(4);
				if (m.chan[j].mux >= m.submaps) {
					throw new VorbisError(INVALID_SETUP);
				}
			}
		} else {
			for (j in 0...channels) {
				m.chan[j].mux = 0;
			}
		}
		
		m.submapFloor = new Vector(m.submaps);
		m.submapResidue = new Vector(m.submaps);
		
		for (j in 0...m.submaps) {
			readBits(8); // discard
			m.submapFloor[j] = readBits(8);
			m.submapResidue[j] = readBits(8);
			if (m.submapFloor[j] >= floorConfig.length) {
				throw new VorbisError(INVALID_SETUP);
			}
			if (m.submapResidue[j] >= residueConfig.length) {
				throw new VorbisError(INVALID_SETUP);
			}
		}
		
		return m;
	}
	
	function readResidue(i:Int):Residue
	{
		var r = new Residue();
		residueTypes[i] = readBits(16);
		if (residueTypes[i] > 2) {
			throw new VorbisError(INVALID_SETUP);
		}
		
		var residueCascade = new Vector<Int>(64);
		r.begin = readBits(24);
		r.end = readBits(24);
		r.partSize = readBits(24)+1;
		r.classifications = readBits(6)+1;
		r.classbook = readBits(8);
		
		for (j in 0...r.classifications) {
			var highBits = 0;
			var lowBits = readBits(3);
			if (readBits(1) != 0){
				highBits = readBits(5);
			}
			residueCascade[j] = highBits * 8 + lowBits;
		}
		
		r.residueBooks = new Vector(r.classifications);
		for (j in 0...r.classifications) {
			r.residueBooks[j] = new Vector(8);
			for (k in 0...8) {
				if (residueCascade[j] & (1 << k) != 0) {
					r.residueBooks[j][k] = readBits(8);
					if (r.residueBooks[j][k] >= codebooks.length) {
						throw new VorbisError(INVALID_SETUP);
					}
				} else {
					r.residueBooks[j][k] = -1;
				}
			}
		}
		
		// precompute the classifications[] array to avoid inner-loop mod/divide
		// call it 'classdata' since we already have r.classifications
		var el = codebooks[r.classbook].entries;
		r.classdata = new Vector(el);
		for (j in 0...el) {
		}
		
		for (j in 0...el) {
			var classwords = codebooks[r.classbook].dimensions;
			var temp = j;
			r.classdata[j] = new Vector(classwords);
			var k = classwords;
			while (--k >= 0) {
				r.classdata[j][k] = temp % r.classifications;
				temp = Std.int(temp / r.classifications);
			}
		}
		
		return r;
	}
	
	function readFloor(i:Int):Floor
	{
		var floor = new Floor();
		
		floorTypes[i] = readBits(16);
		if (floorTypes[i] > 1) {
			throw new VorbisError(INVALID_SETUP);
		}
		if (floorTypes[i] == 0) {
			var g = floor.floor0 = new Floor0();
			g.order = readBits(8);
			g.rate = readBits(16);
			g.barkMapSize = readBits(16);
			g.amplitudeBits = readBits(6);
			g.amplitudeOffset = readBits(8);
			g.numberOfBooks = readBits(4) + 1;
			for (j in 0...g.numberOfBooks) {
				g.bookList[j] = readBits(8);
			}
			throw new VorbisError(FEATURE_NOT_SUPPORTED);
		} else {
			var p = new Array<IntPoint>();
			var g = floor.floor1 = new Floor1();
			var maxClass = -1; 
			g.partitions = readBits(5);
			g.partitionClassList = new Vector(g.partitions);
			for (j in 0...g.partitions) {
				g.partitionClassList[j] = readBits(4);
				if (g.partitionClassList[j] > maxClass) {
					maxClass = g.partitionClassList[j];
				}
			}
			g.classDimensions = new Vector(maxClass + 1);
			g.classMasterbooks = new Vector(maxClass + 1);
			g.classSubclasses = new Vector(maxClass + 1);
			g.subclassBooks = new Vector(maxClass + 1);
			for (j in 0...(maxClass + 1)) {
				g.classDimensions[j] = readBits(3) + 1;
				g.classSubclasses[j] = readBits(2);
				if (g.classSubclasses[j] != 0) {
					g.classMasterbooks[j] = readBits(8);
					if (g.classMasterbooks[j] >= codebooks.length) {
						throw new VorbisError(INVALID_SETUP);
					}
				}
				
				var kl = (1 << g.classSubclasses[j]);
				g.subclassBooks[j] = new Vector(kl);
				for (k in 0...kl) {
					g.subclassBooks[j][k] = readBits(8)-1;
					if (g.subclassBooks[j][k] >= codebooks.length) {
						throw new VorbisError(INVALID_SETUP);
					}
				}
			}
			
			g.floor1Multiplier = readBits(2) + 1;
			g.rangebits = readBits(4);
			g.xlist = new Vector(31*8+2);
			g.xlist[0] = 0;
			g.xlist[1] = 1 << g.rangebits;
			g.values = 2;
			for (j in 0...g.partitions) {
				var c = g.partitionClassList[j];
				for (k in 0...g.classDimensions[c]) {
					g.xlist[g.values] = readBits(g.rangebits);
					g.values++;
				}
			}
			
			// precompute the sorting
			for (j in 0...g.values) {
				p.push(new IntPoint());
				p[j].x = g.xlist[j];
				p[j].y = j;
			}
			
			p.sort(pointCompare);
			
			g.sortedOrder = new Vector(g.values);
			for (j in 0...g.values) {
				g.sortedOrder[j] = p[j].y;
			}
			
			g.neighbors = new Vector(g.values);
			// precompute the neighbors
			for (j in 2...g.values) {
				var ne = neighbors(g.xlist, j);
				g.neighbors[j] = new Vector(g.values);
				g.neighbors[j][0] = ne.low;
				g.neighbors[j][1] = ne.high;
			}

			if (g.values > longestFloorlist) {
				longestFloorlist = g.values;
			}
		}
		
		return floor;
	}
	
	static inline function neighbors(x:Vector<Int>, n:Int) 
	{
		var low = -1;
		var high = 65536;
		var plow  = 0;
		var phigh = 0;
		
		for (i in 0...n) {
			if (x[i] > low  && x[i] < x[n]) { plow  = i; low = x[i]; }
			if (x[i] < high && x[i] > x[n]) { phigh = i; high = x[i]; }
		}
		return {
			low : plow,
			high : phigh,
		}
	}
	
	static inline function pointCompare(a:IntPoint, b:IntPoint) {
		return if (a.x < b.x) -1 else if (a.x > b.x) 1 else 0;
	}
	
	function readCodebook():Codebook {
		var c = new Codebook();
		if (readBits(8) != 0x42 || readBits(8) != 0x43 || readBits(8) != 0x56) {
			throw new VorbisError(VorbisErrorType.INVALID_SETUP); 
		}
		
		var x = readBits(8);
		c.dimensions = (readBits(8) << 8) + x;
		
		var x = readBits(8);
		var y = readBits(8);
		c.entries = (readBits(8) << 16) + (y << 8) + x;
		var ordered = readBits(1);
		c.sparse = (ordered != 0) ? false : (readBits(1) != 0);
		
		var lengths = Bytes.alloc(c.entries);
		if (!c.sparse) {
			c.codewordLengths = lengths;
		}
		
		var total = 0;
		
		if (ordered != 0) {
			var currentEntry = 0;
			var currentLength = readBits(5) + 1;
			
			while (currentEntry < c.entries) {
				var limit = c.entries - currentEntry;
				var n = readBits(MathTools.ilog(limit));
				if (currentEntry + n > c.entries) { 
					throw new VorbisError(VorbisErrorType.INVALID_SETUP, "codebook entrys"); 
				}
				for (i in 0...n) {
					lengths.set(currentEntry + i, currentLength);
				}
				currentEntry += n;
				currentLength++;
			}
		} else {
			for (j in 0...c.entries) {
				var present = (c.sparse) ? readBits(1) : 1;
				if (present != 0) {
					lengths.set(j, readBits(5) + 1);
					total++;
				} else {
					lengths.set(j, NO_CODE);
				}
			}
		}
		
		if (c.sparse && total >= (c.entries >> 2)) {
			//if (c.entries > setupTempMemoryRequired) {
			//	setupTempMemoryRequired = c.entries;
			//}
			
			c.codewordLengths = lengths;
			c.sparse = false;
		}
		
		c.sortedEntries = if (c.sparse) {
			total;
		} else {
			var sortedCount = 0;
			for (j in 0...c.entries) {
				var l = lengths.get(j);
				if (l > VorbisSetting.FAST_HUFFMAN_LENGTH && l != NO_CODE) {
					++sortedCount;
				}
			}
			sortedCount;
		}
		
		var values:Vector<UInt> = null;
		
		if (!c.sparse) {
			c.codewords = new Vector<UInt>(c.entries);
		} else {
			if (c.sortedEntries != 0) {
				c.codewordLengths = Bytes.alloc(c.sortedEntries);
				c.codewords = new Vector<UInt>(c.entries);
				values = new Vector<UInt>(c.entries);
			}
			
			var size:Int = c.entries + (32 + 32) * c.sortedEntries;
			//if (size > setupTempMemoryRequired) {
			//	setupTempMemoryRequired = size;
			//}
		}
		
		if (!computeCodewords(c, lengths, c.entries, values)) {
			throw new VorbisError(VorbisErrorType.INVALID_SETUP, "compute codewords");
		}

		if (c.sortedEntries != 0) {
			// allocate an extra slot for sentinels
			c.sortedCodewords = [];
			
			// allocate an extra slot at the front so that c.sortedValues[-1] is defined
			// so that we can catch that case without an extra if
			c.sortedValues = new Vector<Int>(c.sortedEntries);
			
//			if (c.sortedValues != null) {
//				c.sortedValues; 
//				c.sortedValues[-1] = -1; 
//			}
			computeSortedHuffman(c, lengths, values);
		}

		if (c.sparse) {
			values = null;
			c.codewords = null;
			lengths = null;
		}
		
		computeAcceleratedHuffman(c);
		
		c.lookupType = readBits(4);
		if (c.lookupType > 2) {
			throw new VorbisError(VorbisErrorType.INVALID_SETUP, "codebook lookup type");
		}
		
		if (c.lookupType > 0) {
			c.minimumValue = floatUnpack(readBits(32));
			c.deltaValue = floatUnpack(readBits(32));
			c.valueBits = readBits(4) + 1;
			c.sequenceP = (readBits(1) != 0);
			
			if (c.lookupType == 1) {
				c.lookupValues = lookup1Values(c.entries, c.dimensions);
			} else {
				c.lookupValues = c.entries * c.dimensions;
			}
			
			var mults = new Vector<Int>(c.lookupValues);
			for (j in 0...c.lookupValues) {
				var q = readBits(c.valueBits);
				if (q == EOP) { 
					throw new VorbisError(VorbisErrorType.INVALID_SETUP, "fail lookup"); 
				}
				mults[j] = q;
			}
			
			{
				c.multiplicands = new Vector(c.lookupValues);
				
				//STB_VORBIS_CODEBOOK_FLOATS = true
				for (j in 0...c.lookupValues) {
					c.multiplicands[j] = mults[j] * c.deltaValue + c.minimumValue;
				}
			}
			
			//STB_VORBIS_CODEBOOK_FLOATS = true
			if (c.lookupType == 2 && c.sequenceP) {
				for (j in 1...c.lookupValues) {
					c.multiplicands[j] = c.multiplicands[j - 1];
				}
				c.sequenceP = false;
			}
		}
		
		return c;
	}
	
	static function lookup1Values(entries:Int, dim:Int) 
	{
		var r = Std.int(Math.exp(Math.log(entries) / dim));
		if (Std.int(Math.pow(r + 1, dim)) <= entries) {
			r++;
		}
		
		assert(Math.pow(r+1, dim) > entries);
		assert(Std.int(Math.pow(r, dim)) <= entries); // (int),floor() as above
		return r;
	}
	
	
	
	static function computeAcceleratedHuffman(c:Codebook) 
	{
		for (i in 0...VorbisSetting.FAST_HUFFMAN_TABLE_SIZE()) {
			c.fastHuffman[i] = -1;
		}
		
		var len = (c.sparse) ? c.sortedEntries : c.entries;
		
		//STB_VORBIS_FAST_HUFFMAN_SHORT
		//if (len > 32767) len = 32767; // largest possible value we can encode!
		
		for (i in 0...len) {
			if (c.codewordLengths.get(i) <= VorbisSetting.FAST_HUFFMAN_LENGTH) {
				var z:UInt = (c.sparse) ? bitReverse(c.sortedCodewords[i]) : c.codewords[i];
				// set table entries for all bit combinations in the higher bits
				while (z < VorbisSetting.FAST_HUFFMAN_TABLE_SIZE()) {
					c.fastHuffman[z] = i;
					z += 1 << c.codewordLengths.get(i);
				}
			}
		}
		
	}
	
	static function computeSortedHuffman(c:Codebook, lengths:Bytes, values:Vector<UInt>) 
	{
		// build a list of all the entries
		// OPTIMIZATION: don't include the short ones, since they'll be caught by FAST_HUFFMAN.
		// this is kind of a frivolous optimization--I don't see any performance improvement,
		// but it's like 4 extra lines of code, so.
		if (!c.sparse) {
			var k = 0;
			for (i in 0...c.entries) {
				if (includeInSort(c, lengths.get(i))) {
					c.sortedCodewords[k++] = bitReverse(c.codewords[i]);
				}
			}
			assert(k == c.sortedEntries);
			
		} else {
			for (i in 0...c.sortedEntries) {
				c.sortedCodewords[i] = bitReverse(c.codewords[i]);
			}
		}
		
		c.sortedCodewords[c.sortedEntries] = 0xffffffff;
		c.sortedCodewords.sort(uintAsc);
		
		var len = c.sparse ? c.sortedEntries : c.entries;
		// now we need to indicate how they correspond; we could either
		//	#1: sort a different data structure that says who they correspond to
		//	#2: for each sorted entry, search the original list to find who corresponds
		//	#3: for each original entry, find the sorted entry
		// #1 requires extra storage, #2 is slow, #3 can use binary search!
		for (i in 0...len) {
			var huffLen = c.sparse ? lengths.get(values[i]) : lengths.get(i);
			if (includeInSort(c, huffLen)) {
				var code = bitReverse(c.codewords[i]);
				var x = 0;
				var n = c.sortedEntries;
				while (n > 1) {
					// invariant: sc[x] <= code < sc[x+n]
					var m = x + (n >> 1);
					if (c.sortedCodewords[m] <= code) {
						x = m;
						n -= (n>>1);
					} else {
						n >>= 1;
					}
				}
				
				assert(c.sortedCodewords[x] == code);
				if (c.sparse) {
					c.sortedValues[x] = values[i];
					c.codewordLengths.set(x, huffLen);
				} else {
					c.sortedValues[x] = i;
				}
			}
		}
	}
	
	static private function uintAsc(a:UInt, b:UInt) {
		return if (a < b) {
			-1;
		} else if (a == b){
			0;
		} else {
			1;
		}
	}
	
	static function includeInSort(c:Codebook, len:Int) 
	{
		if (c.sparse) { 
			assert(len != NO_CODE); 
			return true; 
		}
		if (len == NO_CODE) {
			return false;
		}
		if (len > VorbisSetting.FAST_HUFFMAN_LENGTH) {
			return true;
		}
		return false;
	}
	
	static function assert(b:Bool, ?p:PosInfos) {
#if debug
		if (!b) {
			throw new VorbisError(VorbisErrorType.OTHER, "", p);
		}
#end
	}
	
	function computeCodewords(c:Codebook, len:Bytes, n:Int, values:Vector<UInt>) 
	{
		var available = new Vector<UInt>(32);
		for (x in 0...32) available[x] = 0;
		
		// find the first entry
		var k = 0;
		while (k < n) {
			if (len.get(k) < NO_CODE) {
				break;
			}
			k++;
		}
		
		if (k == n) { 
			assert(c.sortedEntries == 0);
			return true; 
		}
		
		var m = 0;
		
		// add to the list
		addEntry(c, 0, k, m++, len.get(k), values);
		
		// add all available leaves
		var i = 0; 
		
		while (++i <= len.get(k)) {
			available[i] = (1:UInt) << ((32 - i):UInt);
		}
		
		// note that the above code treats the first case specially,
		// but it's really the same as the following code, so they
		// could probably be combined (except the initial code is 0,
		// and I use 0 in available[] to mean 'empty')
		i = k;
		while (++i < n) {
			var z = len.get(i);
			if (z == NO_CODE) continue;
			
			// find lowest available leaf (should always be earliest,
			// which is what the specification calls for)
			// note that this property, and the fact we can never have
			// more than one free leaf at a given level, isn't totally
			// trivial to prove, but it seems true and the assert never
			// fires, so!
			while (z > 0 && available[z] == 0) --z;
			if (z == 0) {
				return false; 
			}
			
			var res:UInt = available[z];
			available[z] = 0;
			addEntry(c, bitReverse(res), i, m++, len.get(i), values);
			
			// propogate availability up the tree
			if (z != len.get(i)) {
				var y = len.get(i);
				while (y > z) {
					assert(available[y] == 0);
					available[y] = res + (1 << (32 - y));
					y--;
				}
			}
		}
		
		return true;
	}
	
	static inline function bitReverse(n:UInt):UInt
	{
		n = ((n & 0xAAAAAAAA) >>>  1) | ((n & 0x55555555) << 1);
		n = ((n & 0xCCCCCCCC) >>>  2) | ((n & 0x33333333) << 2);
		n = ((n & 0xF0F0F0F0) >>>  4) | ((n & 0x0F0F0F0F) << 4);
		n = ((n & 0xFF00FF00) >>>  8) | ((n & 0x00FF00FF) << 8);
		return (n >>> 16) | (n << 16);
	}
	
	static inline function addEntry(c:Codebook, huffCode:UInt, symbol:Int, count:Int, len:Int, values:Vector<UInt>) 
	{
		if (!c.sparse) {
			c.codewords[symbol] = huffCode;
		} else {
			c.codewords[count] = huffCode;
			c.codewordLengths.set(count, len);
			values[count] = symbol;
		}
	}
	

	static inline function floatUnpack(x:UInt):Float
	{
		// from the specification
		var mantissa:Float = x & 0x1fffff;
		var sign:Int = x & 0x80000000;
		var exp:Int = (x & 0x7fe00000) >>> 21;
		var res:Float = (sign != 0) ? -mantissa : mantissa;
		return res * Math.pow(2, exp - 788);
	}
	
	
	function readBits(n:Int, ?p:PosInfos):Int
	{
		var z:Int;

		if (validBits < 0) {
			return 0;
		}
		
		if (validBits < n) {
			if (n > 24) {
				// the accumulator technique below would not work correctly in this case
				z = readBits(24);
				z += ((readBits(n - 24) << 24):UInt);
				return z;
			}
			if (validBits == 0) {
				acc = 0;
			}
			
			while (validBits < n) {
				z = readPacketRaw();
				if (z == EOP) {
					validBits = INVALID_BITS;
					return 0;
				}
				acc += (z << validBits);
				validBits += 8;
			}
		}
		if (validBits < 0) {
			return 0;
		}
		
		z = acc & ((1 << n) - 1);
		acc >>>= n;
		validBits -= n;
		return z;
	}
	
	static inline function vorbisValidate(header:Bytes) 
	{
		return header.toString() == "vorbis";
	}
	
	inline function skip(len:Int) 
	{
		stream.read(len);
	}
	
	function nextSegment():Int
	{
		if (lastSeg) {
			return 0;
		}
		
		if (nextSeg == -1) {
			lastSegWhich = segments.length - 1; // in case startPage fails
			
			try {
				startPage();
			} catch(e:VorbisError) {
				lastSeg = true;
				error = e;
				return 0;
			}
			
			if ((pageFlag & VorbisPageFlag.CONTINUED_PACKET) == 0) {
				throw new VorbisError(VorbisErrorType.CONTINUED_PACKET_FLAG_INVALID);
			}
		}
		
		var len = segments.get(nextSeg++);
		if (len < 255) {
			lastSeg = true;
			lastSegWhich = nextSeg - 1;
		}
		if (nextSeg >= segments.length) {
			nextSeg = -1;
		}
		assert(bytesInSeg == 0);
		
		bytesInSeg = len;
		return len;
	}
	
	inline function startPage() 
	{
		capturePattern();
		startPageNoCapturePattern();
	}
	
	function startPageNoCapturePattern() {
		var version = stream.readByte();
		if (version != 0) {
			throw new VorbisError(VorbisErrorType.INVALID_STREAM_STRUCTURE_VERSION, "" + version);
		}
		
		pageFlag = stream.readByte();
		var loc0 = stream.readInt32();
		var loc1 = stream.readInt32();
		
		// stream serial number -- vorbis doesn't interleave, so discard
		stream.readInt32();
		//if (this.serial != get32(f)) throw new VorbisError(VorbisErrorType.incorrectStreamSerialNumber);
		
		// page sequence number
		lastPage = stream.readInt32();
		
		// CRC32
		stream.readInt32();
		
		// pageSegments
		var segmentCount = stream.readByte();
		segments = stream.read(segmentCount);
		
		// assume we Don't_ know any the sample position of any segments
		endSegWithKnownLoc = -2;
		if (loc0 != 0xFFFFFFFF || loc1 != 0xFFFFFFFF) {
			var i:Int = segmentCount - 1;
			while (i >= 0) {
				if (segments.get(i) < 255) {
					break;
				}
				if (i >= 0) {
					endSegWithKnownLoc = i;
					knownLocForPacket = loc0;
				}
				i--;
			}
		}
		
		if (firstDecode) {
			var i:Int = 0;
			var len:Int = 0;
			var p = new ProbedPage();
			
			for (i in 0...segmentCount) {
				len += segments.get(i);
			}
			len += 27 + segmentCount;
			
			p.pageStart = firstAudioPageOffset;
			p.pageStart = firstAudioPageOffset;
			p.pageEnd = p.pageStart + len;
			p.firstDecodedSample = 0;
			p.lastDecodedSample = loc0;
			pFirst = p;
		}
		
		nextSeg = 0;
	}
	
	inline function capturePattern() 
	{
		if (stream.readByte() != 0x4f || stream.readByte() != 0x67 || stream.readByte() != 0x67 || stream.readByte() != 0x53) {
			throw new VorbisError(VorbisErrorType.MISSING_CAPTURE_PATTERN);
		}
	}
	
	function startPacket() {
		while (nextSeg == -1) {
			startPage();
			if ((pageFlag & VorbisPageFlag.CONTINUED_PACKET) != 0) {
				throw new VorbisError(VorbisErrorType.MISSING_CAPTURE_PATTERN);
			}
		}
		
		lastSeg = false;
		validBits = 0;
		packetBytes = 0;
		bytesInSeg = 0;
	}
	
	function maybeStartPacket():Bool
	{
		if (nextSeg == -1) {
			var x = try {
				stream.readByte();
			} catch (e:Eof) {
				eof = true;
				0;
			}
			
			if (eof) {
				return false; // EOF at page boundary is not an error!
			}
			if (x != 0x4f || stream.readByte() != 0x67 || stream.readByte() != 0x67 || stream.readByte() != 0x53) {
				throw new VorbisError(VorbisErrorType.MISSING_CAPTURE_PATTERN);
			}
			
			startPageNoCapturePattern();
			
			if (pageFlag & VorbisPageFlag.CONTINUED_PACKET != 0) {
				// set up enough state that we can read this packet if we want,
				// e.g. during recovery
				lastSeg = false;
				bytesInSeg = 0;
				throw new VorbisError(VorbisErrorType.CONTINUED_PACKET_FLAG_INVALID);
			}
		}
		
		startPacket();
		return true;
	}
	
	function readPacketRaw():Int
	{
		if (bytesInSeg == 0) {  // CLANG!
			if (lastSeg) {
				return EOP;
			} else if (nextSegment() == 0) {
				return EOP;
			}
		}
		assert(bytesInSeg > 0);
		bytesInSeg--;
		packetBytes++;
		return stream.readByte();
	}

	inline function readPacket():Int
	{
		var x = readPacketRaw();
		validBits = 0;
		return x;
	}
	
	inline function flushPacket() 
	{
		while (readPacketRaw() != EOP) {};
	}
	
	inline function decode(c:Codebook):Int {
		var val = decodeRaw(c);
		if (c.sparse) {
			val = c.sortedValues[val];
		}
		return val;
	}
	
	inline function decodeVq(c:Codebook) 
	{
		return decode(c);
	}
	
	function decodeRaw(c:Codebook)
	{
		if (validBits < VorbisSetting.FAST_HUFFMAN_LENGTH){
			prepHuffman();
		}
		
		// fast huffman table lookup
		var index = acc & VorbisSetting.FAST_HUFFMAN_TABLE_MASK();
		var i = c.fastHuffman[index];
		
		if (i >= 0) {
			acc >>>= c.codewordLengths.get(i);
			validBits -= c.codewordLengths.get(i);
			if (validBits < 0) { 
				validBits = 0;
				return -1; 
			}
			return i;
		}
		
		return codebookDecodeScalarRaw(c);
	}
	
	function prepHuffman() 
	{
		if (validBits <= 24) {
			if (validBits == 0) { 
				acc = 0;
			}
			do {
				if (lastSeg && bytesInSeg == 0) {
					return;
				}
				var z = readPacketRaw();
				if (z == EOP) {
					return;
				}
				acc += z << validBits;
				validBits += 8;
			} while (validBits <= 24);
		}
	}

	function codebookDecodeScalarRaw(c:Codebook):Int
	{
		prepHuffman();

		assert(c.sortedCodewords != null || c.codewords != null);
		// cases to use binary search: sortedCodewords && !c.codewords
		
		if (c.entries > 8 ? (c.sortedCodewords != null) : c.codewords != null) {
			// binary search
			var code = bitReverse(acc);
			var x = 0; 
			var n = c.sortedEntries;
			
			while (n > 1) {
				// invariant: sc[x] <= code < sc[x+n]
				var m = x + (n >> 1);
				if (c.sortedCodewords[m] <= code) {
					x = m;
					n -= (n>>1);
				} else {
					n >>= 1;
				}
			}
			
			// x is now the sorted index
			if (!c.sparse) {
				x = c.sortedValues[x];
			}
			
			// x is now sorted index if sparse, or symbol otherwise
			var len = c.codewordLengths.get(x);
			if (validBits >= len) {
				acc >>>= len;
				validBits -= len;
				return x;
			}

			validBits = 0;
			return -1;
		}

		// if small, linear search
		assert(!c.sparse);
		for (i in 0...c.entries) {
			if (c.codewordLengths.get(i) == NO_CODE) continue;
			if (c.codewords[i] == (acc & ((1 << c.codewordLengths.get(i))-1))) {
				if (validBits >= c.codewordLengths.get(i)) {
					acc >>>= c.codewordLengths.get(i);
					validBits -= c.codewordLengths.get(i);
					return i;
				}
				validBits = 0;
				return -1;
			}
		}

		error = new VorbisError(INVALID_STREAM);
		validBits = 0;
		return -1;
	}

}
