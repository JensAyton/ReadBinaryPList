/*

ReadBinaryPList.m

Reader for binary property list files (version 00).

This has been found to work on all 566 binary plists in my ~/Library/Preferences/
and /Library/Preferences/ directories. This probably does not provide full
test coverage. It has also been found to provide different data to Apple's
implementation when presented with a key-value archive. This is because Apple's
implementation produces undocumented CFKeyArchiverUID objects. My implementation
produces dictionaries instead, matching the in-file representation used in XML
and OpenStep plists. See ExtractUID().

Full disclosure: in implementing this software, I read one comment and one
struct defintion in CFLite, Apple's implementation, which is under the APSL
license. I also deduced the information about CFKeyArchiverUID from that code.
However, none of the implementation was copied.


Copyright (C) 2007 Jens Ayton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

#import "ReadBinaryPList.h"


#if 0
#define BPListLog NSLog
#else
#define BPListLog(...)
#endif

#if 0
#define BPListLogVerbose BPListLog
#else
#define BPListLogVerbose(...)
#endif


typedef struct BPListTrailer
{
	uint8_t				unused[6];
	uint8_t				offsetIntSize;
	uint8_t				objectRefSize;
	uint64_t			objectCount;
	uint64_t			topLevelObject;
	uint64_t			offsetTableOffset;
} BPListTrailer;


enum
{
	kHeaderSize			= 8,
	kTrailerSize		= sizeof (BPListTrailer),
	kMinimumSaneSize	= kHeaderSize + kTrailerSize
};


enum
{
	// Object tags (high nybble)
	kTagSimple			= 0x00,	// Null, true, false, filler, or invalid
	kTagInt				= 0x10,
	kTagReal			= 0x20,
	kTagDate			= 0x30,
	kTagData			= 0x40,
	kTagASCIIString		= 0x50,
	kTagUnicodeString	= 0x60,
	kTagUID				= 0x80,
	kTagArray			= 0xA0,
	kTagDictionary		= 0xD0,
	
	// "simple" object values
	kValueNull			= 0x00,
	kValueFalse			= 0x08,
	kValueTrue			= 0x09,
	kValueFiller		= 0x0F,
	
	kValueFullDateTag	= 0x33	// Dates are tagged with a whole byte.
};


static const char kHeaderBytes[kHeaderSize] = "bplist00";


typedef struct BPListInfo
{
	uint64_t			objectCount;
	const uint8_t		*dataBytes;
	uint64_t			length;
	uint64_t			offsetTableOffset;
	uint8_t				offsetIntSize;
	uint8_t				objectRefSize;
	NSMutableDictionary	*cache;
} BPListInfo;


static uint64_t ReadSizedInt(BPListInfo bplist, uint64_t offset, uint8_t size);
static uint64_t ReadOffset(BPListInfo bplist, uint64_t index);
static BOOL ReadSelfSizedInt(BPListInfo bplist, uint64_t offset, uint64_t *outValue, size_t *outSize);

static id ExtractObject(BPListInfo bplist, uint64_t objectRef);

static id ExtractSimple(BPListInfo bplist, uint64_t offset);
static id ExtractInt(BPListInfo bplist, uint64_t offset);
static id ExtractReal(BPListInfo bplist, uint64_t offset);
static id ExtractDate(BPListInfo bplist, uint64_t offset);
static id ExtractData(BPListInfo bplist, uint64_t offset);
static id ExtractASCIIString(BPListInfo bplist, uint64_t offset);
static id ExtractUnicodeString(BPListInfo bplist, uint64_t offset);
static id ExtractUID(BPListInfo bplist, uint64_t offset);
static id ExtractArray(BPListInfo bplist, uint64_t offset);
static id ExtractDictionary(BPListInfo bplist, uint64_t offset);


BOOL IsBinaryPList(NSData *data)
{
	if ([data length] < kMinimumSaneSize)  return NO;
	return memcmp([data bytes], kHeaderBytes, kHeaderSize) == 0;
}


id ReadBinaryPList(NSData *data)
{
	if (data == nil)  return nil;
	if (!IsBinaryPList(data))
	{
		BPListLog(@"Bad binary plist: too short or invalid header.");
		return nil;
	}
	
	// Read trailer
	BPListTrailer *trailer = (BPListTrailer *)([data bytes] + [data length] - kTrailerSize);
	
	// Basic sanity checks
	if (trailer->offsetIntSize < 1 || trailer->offsetIntSize > 8 ||
		trailer->objectRefSize < 1 || trailer->objectRefSize > 8 ||
		trailer->offsetTableOffset < kHeaderSize)
	{
		BPListLog(@"Bad binary plist: trailer declared insane.");
		return nil;		
	}
	
	// Ensure offset table is inside file
	uint64_t offsetTableSize = trailer->offsetIntSize * trailer->objectCount;
	if (offsetTableSize + trailer->offsetTableOffset + kTrailerSize > [data length])
	{
		BPListLog(@"Bad binary plist: offset table overlaps end of container.");
		return nil;
	}
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	id result = nil;
	@try
	{
		BPListInfo bplist =
		{
			trailer->objectCount,
			[data bytes],
			[data length],
			trailer->offsetTableOffset,
			trailer->offsetIntSize,
			trailer->objectRefSize,
			[NSMutableDictionary dictionary]
		};
		
		BPListLogVerbose(@"Got a sane bplist with %llu items, offsetIntSize: %u, objectRefSize: %u", trailer->objectCount, trailer->offsetIntSize, trailer->objectRefSize);
		
		result = ExtractObject(bplist, trailer->topLevelObject);
		[result retain];
	}
	@finally
	{
		[pool release];
	}
	
	return [result autorelease];
}


static id ExtractObject(BPListInfo bplist, uint64_t objectRef)
{
	uint64_t				offset;
	NSNumber				*cacheKey = nil;
	id						result = nil;
	uint8_t					objectTag;
	
	if (objectRef >= bplist.objectCount)
	{
		// Out-of-range object reference.
		BPListLog(@"Bad binary plist: object index is out of range.");
		return nil;
	}
	
	// Use cached object if it exists
	cacheKey = [NSNumber numberWithUnsignedLongLong:objectRef];
	result = [bplist.cache objectForKey:cacheKey];
	if (result != nil)  return result;
	
	// Otherwise, find object in file.
	offset = ReadOffset(bplist, objectRef);
	if (offset > bplist.length)
	{
		// Out-of-range offset.
		BPListLog(@"Bad binary plist: object outside container.");
		return nil;
	}
	objectTag = *(bplist.dataBytes + offset);
	switch (objectTag & 0xF0)
	{
		case kTagSimple:
			result = ExtractSimple(bplist, offset);
			break;
		
		case kTagInt:
			result = ExtractInt(bplist, offset);
			break;
			
		case kTagReal:
			result = ExtractReal(bplist, offset);
			break;
			
		case kTagDate:
			result = ExtractDate(bplist, offset);
			break;
			
		case kTagData:
			result = ExtractData(bplist, offset);
			break;
			
		case kTagASCIIString:
			result = ExtractASCIIString(bplist, offset);
			break;
			
		case kTagUnicodeString:
			result = ExtractUnicodeString(bplist, offset);
			break;
			
		case kTagUID:
			result = ExtractUID(bplist, offset);
			break;
			
		case kTagArray:
			result = ExtractArray(bplist, offset);
			break;
			
		case kTagDictionary:
			result = ExtractDictionary(bplist, offset);
			break;
			
		default:
			// Unknown tag.
			BPListLog(@"Bad binary plist: unknown tag 0x%X.", (objectTag & 0x0F) >> 4);
			result = nil;
	}
	
	// Cache and return result.
	if (result != nil)  [bplist.cache setObject:result forKey:cacheKey];
	return result;
}


static uint64_t ReadSizedInt(BPListInfo bplist, uint64_t offset, uint8_t size)
{
	assert(bplist.dataBytes != NULL && size >= 1 && size <= 8 && offset + size <= bplist.length);
	
	uint64_t		result = 0;
	const uint8_t	*byte = bplist.dataBytes + offset;
	
	do
	{
		result = (result << 8) | *byte++;
	} while (--size);
	
	return result;
}


static uint64_t ReadOffset(BPListInfo bplist, uint64_t index)
{
	assert(index < bplist.objectCount);
	
	return ReadSizedInt(bplist, bplist.offsetTableOffset + bplist.offsetIntSize * index, bplist.offsetIntSize);
}


static BOOL ReadSelfSizedInt(BPListInfo bplist, uint64_t offset, uint64_t *outValue, size_t *outSize)
{
	uint32_t			size;
	int64_t				value;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	size = 1 << (bplist.dataBytes[offset] & 0x0F);
	if (size > 8)
	{
		// Maximum allowable size in this implementation is 1<<3 = 8 bytes.
		// This also happens to be the biggest NSNumber can handle.
		return NO;
	}
	
	if (offset + 1 + size > bplist.length)
	{
		// Out of range.
		return NO;
	}
	
	value = ReadSizedInt(bplist, offset + 1, size);
	
	if (outValue != NULL)  *outValue = value;
	if (outSize != NULL)  *outSize = size + 1; // +1 for tag byte.
	return YES;
}


static id ExtractSimple(BPListInfo bplist, uint64_t offset)
{
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	switch (bplist.dataBytes[offset])
	{
		case kValueNull:
			return [NSNull null];
			
		case kValueTrue:
			return [NSNumber numberWithBool:YES];
			
		case kValueFalse:
			return [NSNumber numberWithBool:NO];
	}
	
	// Note: kValueFiller is treated as invalid, because it, er, is.
	BPListLog(@"Bad binary plist: invalid atom.");
	return nil;
}


static id ExtractInt(BPListInfo bplist, uint64_t offset)
{
	uint64_t			value;
	
	if (!ReadSelfSizedInt(bplist, offset, &value, NULL))
	{
		BPListLog(@"Bad binary plist: invalid integer object.");
	}
	
	/*	NOTE: originally, I sign-extended here. This was the wrong thing; it
		turns out that negative ints are always stored as 64-bit, and smaller
		ints are unsigned.
	*/
	
	return [NSNumber numberWithLongLong:(int64_t)value];
}


static id ExtractReal(BPListInfo bplist, uint64_t offset)
{
	uint32_t			size;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	size = 1 << (bplist.dataBytes[offset] & 0x0F);
	
	// FIXME: what to do if faced with other sizes for float/double?
	assert (sizeof (float) == sizeof (uint32_t) && sizeof (double) == sizeof (uint64_t));
	
	if (offset + 1 + size > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"floating-point number");
		return nil;
	}
	
	if (size == sizeof (float))
	{
		uint32_t value = ReadSizedInt(bplist, offset + 1, size);	// Note that this handles byte swapping.
		return [NSNumber numberWithFloat:*(float *)&value];
	}
	else if (size == sizeof (double))
	{
		uint64_t value = ReadSizedInt(bplist, offset + 1, size);	// Note that this handles byte swapping.
		return [NSNumber numberWithDouble:*(double *)&value];
	}
	else
	{
		// Can't handle floats of other sizes.
		BPListLog(@"Bad binary plist: can't handle %u-byte float.", size);
		return nil;
	}
}


static id ExtractDate(BPListInfo bplist, uint64_t offset)
{
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	// Data has size code like int and real, but only 3 (meaning 8 bytes) is valid.
	if (bplist.dataBytes[offset] != kValueFullDateTag)
	{
		BPListLog(@"Bad binary plist: invalid size for date object.");
		return nil;
	}
	
	if (offset + 1 + sizeof (double) > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"date");
		return nil;
	}
	
	// FIXME: what to do if faced with other sizes for double?
	assert (sizeof (double) == sizeof (uint64_t));
	
	uint64_t value = ReadSizedInt(bplist, offset + 1, sizeof (double));	// Note that this handles byte swapping.
	return [NSDate dateWithTimeIntervalSinceReferenceDate:*(double *)&value];
}


static id ExtractData(BPListInfo bplist, uint64_t offset)
{
	uint64_t			size;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	size = bplist.dataBytes[offset] & 0x0F;
	offset++;
	if (size == 0x0F)
	{
		// 0x0F means separate int size follows. Smaller values are used for short data.
		size_t			extra;
		if (!ReadSelfSizedInt(bplist, offset, &size, &extra))
		{
			BPListLog(@"Bad binary plist: invalid %@ object size tag.", @"data");
			return nil;
		}
		
		if ((bplist.dataBytes[offset] & 0xF0) != kTagInt)
		{
			// Bad data, mistagged size int
			BPListLog(@"Bad binary plist: %@ object size is not tagged as int.", @"data");
			return nil;
		}
		
		offset += extra;
	}
	
	if (offset + size > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"data");
		return nil;
	}
	
	return [NSData dataWithBytes:bplist.dataBytes + offset length:size];
}


static id ExtractASCIIString(BPListInfo bplist, uint64_t offset)
{
	uint64_t			size;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	size = bplist.dataBytes[offset] & 0x0F;
	offset++;
	if (size == 0x0F)
	{
		// 0x0F means separate int size follows. Smaller values are used for short data.
		size_t			extra;
		if (!ReadSelfSizedInt(bplist, offset, &size, &extra))
		{
			BPListLog(@"Bad binary plist: invalid %@ object size tag.", @"string");
			return nil;
		}
		
		if ((bplist.dataBytes[offset] & 0xF0) != kTagInt)
		{
			// Bad data, mistagged size int
			BPListLog(@"Bad binary plist: %@ object size is not tagged as int.", @"string");
			return nil;
		}
		
		offset += extra;
	}
	
	if (offset + size > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"string");
		return nil;
	}
	
	return [[NSString alloc] initWithBytes:bplist.dataBytes + offset length:size encoding:NSASCIIStringEncoding];
}


static id ExtractUnicodeString(BPListInfo bplist, uint64_t offset)
{
	uint64_t			size;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	size = bplist.dataBytes[offset] & 0x0F;
	offset++;
	if (size == 0x0F)
	{
		// 0x0F means separate int size follows. Smaller values are used for short data.
		size_t			extra;
		if (!ReadSelfSizedInt(bplist, offset, &size, &extra))
		{
			BPListLog(@"Bad binary plist: invalid %@ object size tag.", @"string");
			return nil;
		}
		
		if ((bplist.dataBytes[offset] & 0xF0) != kTagInt)
		{
			// Bad data, mistagged size int
			BPListLog(@"Bad binary plist: %@ object size is not tagged as int.", @"string");
			return nil;
		}
		
		offset += extra;
	}
	
	if (offset + size > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"string");
		return nil;
	}
	
	return [[NSString alloc] initWithBytes:bplist.dataBytes + offset length:size * 2 encoding:NSUTF16BigEndianStringEncoding];
}


static id ExtractUID(BPListInfo bplist, uint64_t offset)
{
	/*	UIDs are used by Cocoa's key-value coder.
		When writing other plist formats, they are expanded to dictionaries of
		the form <dict><key>CF$UID</key><integer>value</integer></dict>, so we
		do the same here on reading. This results in plists identical to what
		running plutil -convert xml1 gives us. However, this is not the same
		result as [Core]Foundation's plist parser, which extracts them as un-
		introspectable CF objects. In fact, it even seems to convert the CF$UID
		dictionaries from XML plists on the fly.
	*/
	
	uint64_t			value;
	
	if (!ReadSelfSizedInt(bplist, offset, &value, NULL))
	{
		BPListLog(@"Bad binary plist: invalid UID object.");
		return nil;
	}
	
	return [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLongLong:value] forKey:@"CF$UID"];
}


static id ExtractArray(BPListInfo bplist, uint64_t offset)
{
	uint64_t			i, count;
	uint64_t			size;
	uint64_t			elementID;
	id					element = nil;
	id					*array = NULL;
	NSArray				*result = nil;
	BOOL				OK = YES;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	count = bplist.dataBytes[offset] & 0x0F;
	offset++;
	if (count == 0x0F)
	{
		// 0x0F means separate int count follows. Smaller values are used for short data.
		size_t			extra;
		if (!ReadSelfSizedInt(bplist, offset, &count, &extra))
		{
			BPListLog(@"Bad binary plist: invalid %@ object size tag.", @"array");
			return nil;
		}
		
		if ((bplist.dataBytes[offset] & 0xF0) != kTagInt)
		{
			// Bad data, mistagged count int
			BPListLog(@"Bad binary plist: %@ object size is not tagged as int.", @"array");
			return nil;
		}
		
		offset += extra;
	}
	
	if (count > UINT64_MAX / bplist.objectRefSize - offset)
	{
		// Offset overflow.
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"array");
		return nil;
	}
	
	size = bplist.objectRefSize * count;
	if (size + offset > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"array");
		return nil;
	}
	
	if (count == 0)  return [NSArray array];
	
	array = malloc(sizeof (id) * count);
	if (array == NULL)
	{
		BPListLog(@"Not enough memory to read plist.");
		return nil;
	}
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	@try
	{
		for (i = 0; i != count; ++i)
		{
			BPListLogVerbose(@"[%u]", i);
			elementID = ReadSizedInt(bplist, offset + i * bplist.objectRefSize, bplist.objectRefSize);
			element = ExtractObject(bplist, elementID);
			if (element != nil)
			{
				array[i] = element;
			}
			else
			{
				OK = NO;
				break;
			}
		}
		if (OK)  result = [[NSArray alloc] initWithObjects:array count:count];
	}
	@finally
	{
		free(array);
		[pool release];
	}
	
	return [result autorelease];
}


static id ExtractDictionary(BPListInfo bplist, uint64_t offset)
{
	uint64_t			i, count;
	uint64_t			size;
	uint64_t			elementID;
	id					element = nil;
	id					*keys = NULL;
	id					*values = NULL;
	NSDictionary		*result = nil;
	BOOL				OK = YES;
	
	assert(bplist.dataBytes != NULL && offset < bplist.length);
	
	count = bplist.dataBytes[offset] & 0x0F;
	offset++;
	if (count == 0x0F)
	{
		// 0x0F means separate int count follows. Smaller values are used for short data.
		size_t			extra;
		if (!ReadSelfSizedInt(bplist, offset, &count, &extra))
		{
			BPListLog(@"Bad binary plist: invalid %@ object size tag.", @"dictionary");
			return nil;
		}
		
		if ((bplist.dataBytes[offset] & 0xF0) != kTagInt)
		{
			// Bad data, mistagged count int
			BPListLog(@"Bad binary plist: %@ object size is not tagged as int.", @"dictionary");
			return nil;
		}
		
		offset += extra;
	}
	
	if (count > UINT64_MAX / (bplist.objectRefSize * 2) - offset)
	{
		// Offset overflow.
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"dictionary");
		return nil;
	}
	
	size = bplist.objectRefSize * count * 2;
	if (size + offset > bplist.length)
	{
		BPListLog(@"Bad binary plist: %@ object overlaps end of container.", @"dictionary");
		return nil;
	}
	
	if (count == 0)  return [NSDictionary dictionary];
	
	keys = malloc(sizeof (id) * count);
	if (keys == NULL)
	{
		BPListLog(@"Not enough memory to read plist.");
		return nil;
	}
	
	values = malloc(sizeof (id) * count);
	if (values == NULL)
	{
		free(keys);
		BPListLog(@"Not enough memory to read plist.");
		return nil;
	}
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	@try
	{
		for (i = 0; i != count; ++i)
		{
			elementID = ReadSizedInt(bplist, offset + i * bplist.objectRefSize, bplist.objectRefSize);
			element = ExtractObject(bplist, elementID);
			if (element != nil)
			{
				keys[i] = element;
				BPListLogVerbose(@"%@", element);
			}
			else
			{
				OK = NO;
				break;
			}
			
			elementID = ReadSizedInt(bplist, offset + (i + count) * bplist.objectRefSize, bplist.objectRefSize);
			element = ExtractObject(bplist, elementID);
			if (element != nil)
			{
				values[i] = element;
			}
			else
			{
				OK = NO;
				break;
			}
		}
		if (OK)  result = [[NSDictionary alloc] initWithObjects:values forKeys:keys count:count];
	}
	@finally
	{
		free(keys);
		free(values);
		[pool release];
	}
	
	return [result autorelease];
}

