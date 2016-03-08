############################################################
#                                                          #
#                          hprose                          #
#                                                          #
# Official WebSite: http://www.hprose.com/                 #
#                   http://www.hprose.org/                 #
#                                                          #
############################################################

############################################################
#                                                          #
# hprose/io/writer.nim                                     #
#                                                          #
# hprose writer for Nim                                    #
#                                                          #
# LastModified: Mar 9, 2016                                #
# Author: Ma Bingyao <andot@hprose.com>                    #
#                                                          #
############################################################

import typeinfo, tables, sets, lists, queues, intsets, streams, times
import tags

type
    WriterRefer = ref object of RootObj

    FakeWriterRefer = ref object of WriterRefer

    RealWriterRefer = ref object of WriterRefer
        stream: Stream
        references: Table[pointer, int]
        refcount: int

method setRef(wr: WriterRefer, p: pointer) {.base, inline.} = discard
method writeRef(wr: WriterRefer, p: pointer): bool {.base, inline.} = false
method resetRef(wr: WriterRefer) {.base, inline.} = discard

proc newFakeWriterRefer(): FakeWriterRefer = new(result)

method setRef(wr: RealWriterRefer, p: pointer) {.inline.} =
    if p != nil: wr.references[p] = wr.refcount
    inc wr.refcount

method writeRef(wr: RealWriterRefer, p: pointer): bool {.inline.} =
    if p == nil: return false
    if wr.references.hasKey p:
        var i = wr.references[p]
        wr.stream.write tag_ref
        wr.stream.write $i
        wr.stream.write tag_semicolon
        return true
    return false

method resetRef(wr: RealWriterRefer) {.inline.} =
    wr.references = initTable[pointer, int]();
    wr.refcount = 0;

proc newRealWriterRefer(stream: Stream): RealWriterRefer =
    new result
    result.stream = stream
    result.resetRef

type
    Writer* = ref object of RootObj
        stream*: Stream
        refer: WriterRefer
        classref: Table[string, int]
        crcount: int

proc newWriter*(stream: Stream, simple: bool = false): Writer {.inline.} =
    new result
    result.stream = stream
    if simple:
        result.refer = newFakeWriterRefer()
    else:
        result.refer = newRealWriterRefer stream

proc reset*(writer: Writer) {.inline.} =
    writer.refer.reset
    writer.classref = initTable[string, int]()
    writer.crcount = 0

proc writeNull*(writer: Writer) {.inline.} = writer.stream.write tag_null

proc writeInt*[T: SomeInteger](writer: Writer, value: T) {.inline.} =
    let stream = writer.stream
    if T(0) <= value and value <= T(9):
        stream.write $value
    else:
        when T is int8|int16|int32|uint8|uint16:
            stream.write tag_integer
        when T is int|int64:
            stream.write if T(low(int32)) <= value and value <= T(high(int32)): tag_integer else: tag_long
        when T is uint|uint32|uint64:
            stream.write if value <= T(high(int32)): tag_integer else: tag_long
        stream.write $value
        stream.write tag_semicolon

proc writeLong*[T: SomeInteger](writer: Writer, value: T) {.inline.} =
    let stream = writer.stream
    if value >= T(0) and value <= T(9):
        stream.write $value
    else:
        stream.write tag_long
        stream.write $value
        stream.write tag_semicolon

proc writeDouble*[T: SomeReal](writer: Writer, value: T) {.inline.} =
    let stream = writer.stream
    if value != value:
        stream.write tag_nan
    elif float(value).abs >= Inf:
        stream.write tag_infinity
        stream.write if value > 0: tag_pos else: tag_neg
    else:
        stream.write tag_double
        stream.write $value
        stream.write tag_semicolon

proc writeBool*(writer: Writer, value: bool) {.inline.} =
    writer.stream.write if value: tag_true else: tag_false

proc writeChar(writer: Writer, value: char) {.inline.} =
    let stream = writer.stream
    if value.ord < 0x80:
        stream.write tag_utf8char
        stream.write value
    else:
        stream.write tag_bytes
        stream.write "1"
        stream.write tag_quote
        stream.write value
        stream.write tag_quote

proc writeDateTime*(writer: Writer, value: TimeInfo) {.inline.} =
    if value.year < 0: raise newException(RangeError, "Years BC is not supported in hprose.")
    if value.year > 9999: raise newException(RangeError, "Year after 9999 is not supported in hprose.")
    let stream = writer.stream
    let timezone = if value.timezone == 0: tag_utc else: tag_semicolon
    if value.hour == 0 and value.minute == 0 and value.second == 0:
        stream.write tag_date
        stream.write value.format("yyyyMMdd")
        stream.write timezone
    elif value.year == 1970 and value.month == mJan and value.monthday == 1:
        stream.write tag_time
        stream.write value.format("HHmmss")
        stream.write timezone
    else:
        stream.write tag_date
        stream.write value.format("yyyyMMdd'" & tag_time & "'HHmmss")
        stream.write timezone

proc ulen(s: string): int =
  ## Returns the number of utf16 characters of the string ``s``
  ## if s is not a valid utf8 string, return -1
  if isNil(s): return 0
  var i = 0
  var n = s.xlen
  while i < n:
    if s[i].ord <=% 127: inc i
    elif s[i].ord shr 5 == 0b110: inc i, 2
    elif s[i].ord shr 4 == 0b1110: inc i, 3
    elif s[i].ord shr 3 == 0b11110: inc i, 4; inc result
    else: return -1
    if i > n: return -1
    inc result

proc writeBytesInternal(writer: Writer, value: string) {.inline.} =
    let stream = writer.stream
    stream.write tag_bytes
    var n = value.xlen
    if n > 0:
        stream.write $n
        stream.write tag_quote
        stream.write value
    else:
        stream.write tag_quote
    stream.write tag_quote

proc writeStringInternal(writer: Writer, value: string, n: int) {.inline.} =
    let stream = writer.stream
    stream.write tag_string
    if n > 0:
        stream.write $n
        stream.write tag_quote
        stream.write value
    else:
        stream.write tag_quote
    stream.write tag_quote

proc writeBytes*(writer: Writer, value: string) {.inline.} =
    writer.refer.setRef cast[pointer](value)
    writer.writeBytesInternal value

proc writeString*(writer: Writer, value: string) {.inline.} =
    writer.refer.setRef cast[pointer](value)
    let n = value.ulen
    if n == -1:
        writer.writeBytesInternal value
    else:
        writer.writeStringInternal value, n

proc writeBytesWithRef*(writer: Writer, value: string) {.inline.} =
    if not writer.refer.writeRef cast[pointer](value): writer.writeBytes value

proc writeStringWithRef(writer: Writer, value: string, n: int) {.inline.} =
    if not writer.refer.writeRef cast[pointer](value):
        writer.refer.setRef cast[pointer](value)
        writer.writeStringInternal value, n

proc writeStringWithRef*(writer: Writer, value: string) {.inline.} =
    if not writer.refer.writeRef cast[pointer](value): writer.writeString value

proc writeList[T](writer: Writer, value: T, n: int) =
    let stream = writer.stream
    stream.write tag_list
    if n > 0:
        stream.write $n
        stream.write tag_openbrace
        for e in value: writer.serialize e
    else:
        stream.write tag_openbrace
    stream.write tag_closebrace

proc writeSeq[T](writer: Writer, value: seq[T]) {.inline.} =
    writer.writeList value, value.xlen

proc writeSeq(writer: Writer, value: seq[byte]) {.inline.} =
    writer.writeBytesInternal cast[string](value)

proc writeSeqWithRef*[T](writer: Writer, value: seq[T]) {.inline.} =
    let p = cast[pointer](value)
    if not writer.refer.writeRef p:
        writer.refer.setRef p
        writer.writeSeq value

proc writeArray[I, T](writer: Writer, value: array[I, T]) {.inline.} =
    writer.writeList value, value.len

proc writeArray[I](writer: Writer, value: array[I, byte]) {.inline.} =
    writer.writeBytesInternal cast[string](@value)

proc writeList[T](writer: Writer, value: T) =
    var stream = writer.stream
    var ss = newStringStream()
    writer.stream = ss
    var n = 0
    for e in value:
        writer.serialize e
        inc n
    writer.stream = stream
    stream.write tag_list
    if n > 0:
        stream.write $n
        stream.write tag_openbrace
        stream.write ss.data
    else:
        stream.write tag_openbrace
    stream.write tag_closebrace

proc writeInternal[T](writer: Writer, value: T) {.inline.} =
    when T is SomeInteger: writer.writeInt value
    when T is SomeReal: writer.writeDouble value
    when T is bool: writer.writeBool value
    when T is char: writer.writeChar value
    when T is TimeInfo: writer.writeDateTime value
    when T is array: writer.writeArray value
    when T is set: writer.writeList value, value.card
    when T is Queue|HashSet|OrderedSet: writer.writeList value, value.len
    when T is IntSet|SinglyLinkedList|DoublyLinkedList|SinglyLinkedRing|DoublyLinkedRing: writer.writeList value

proc writeRefPtr[T](writer: Writer, value: ref T|ptr T) =
    when T is SomeInteger|SomeReal|bool|char:
        writer.writeInternal value[]
    else:
        let p = cast[pointer](value)
        if not writer.refer.writeRef p:
            writer.refer.setRef p
            writer.writeInternal value[]

proc writeValue[T](writer: Writer, value: T) =
    when T is SomeInteger|SomeReal|bool|char:
        writer.writeInternal value
    else:
        writer.refer.setRef nil
        writer.writeInternal value

proc serialize*[T](writer: Writer, value: T) =
    when T is ref|ptr:
        if value.isNil:
            writer.writeNull
        else:
            writer.writeRefPtr value
    elif T is string:
        if value.isNil:
            writer.writeNull
        else:
            let n = value.ulen
            if n == -1:
                writer.writeBytesWithRef value
            elif n == 0:
                writer.stream.write tag_empty
            elif n == 1:
                writer.stream.write tag_utf8char
                writer.stream.write value
            else:
                writer.writeStringWithRef value, n
    elif T is seq:
        if value.isNil:
            writer.writeNull
        else:
            writer.writeSeqWithRef value
    else:
        writer.writeValue value

proc serialize*(writer: Writer, value: RootRef) {.inline.} = writer.writeNull

when defined(test):
    import unittest
    suite "hprose.io.writer":
        echo "Writer:"
        test "serialize(nil)":
            var writer = newWriter(newStringStream())
            writer.serialize(nil)
            check StringStream(writer.stream).data == "n"
        test "serialize(0)":
            var writer = newWriter(newStringStream())
            writer.serialize(0)
            check StringStream(writer.stream).data == "0"
        test "serialize(1)":
            var writer = newWriter(newStringStream())
            writer.serialize(1)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'i8)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'i8)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'u8)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'u8)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'i16)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'i16)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'u16)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'u16)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'i32)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'i32)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'u32)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'u32)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'i64)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'i64)
            check StringStream(writer.stream).data == "1"
        test "serialize(1'u64)":
            var writer = newWriter(newStringStream())
            writer.serialize(1'u64)
            check StringStream(writer.stream).data == "1"
        test "serialize(high(int32))":
            var writer = newWriter(newStringStream())
            writer.serialize(high(int32))
            check StringStream(writer.stream).data == 'i' & $high(int32) & ';'
        test "serialize(low(int32))":
            var writer = newWriter(newStringStream())
            writer.serialize(low(int32))
            check StringStream(writer.stream).data == 'i' & $low(int32) & ';'
        test "serialize(high(int64))":
            var writer = newWriter(newStringStream())
            writer.serialize(high(int64))
            check StringStream(writer.stream).data == 'l' & $high(int64) & ';'
        test "serialize(low(int64))":
            var writer = newWriter(newStringStream())
            writer.serialize(low(int64))
            check StringStream(writer.stream).data == 'l' & $low(int64) & ';'
        test "serialize(low(int64))":
            var writer = newWriter(newStringStream())
            writer.serialize(low(int64))
            check StringStream(writer.stream).data == 'l' & $low(int64) & ';'
        test "serialize(NaN)":
            var writer = newWriter(newStringStream())
            writer.serialize(NaN)
            check StringStream(writer.stream).data == "N"
        test "serialize(Inf)":
            var writer = newWriter(newStringStream())
            writer.serialize(Inf)
            check StringStream(writer.stream).data == "I+"
        test "serialize(-Inf)":
            var writer = newWriter(newStringStream())
            writer.serialize(-Inf)
            check StringStream(writer.stream).data == "I-"
        test "serialize(3.1415926)":
            var writer = newWriter(newStringStream())
            writer.serialize(3.1415926)
            check StringStream(writer.stream).data == "d3.1415926;"
        test "serialize(0.0)":
            var writer = newWriter(newStringStream())
            writer.serialize(0.0)
            check StringStream(writer.stream).data == "d0.0;"
        test "serialize(true)":
            var writer = newWriter(newStringStream())
            writer.serialize(true)
            check StringStream(writer.stream).data == "t"
        test "serialize(false)":
            var writer = newWriter(newStringStream())
            writer.serialize(false)
            check StringStream(writer.stream).data == "f"
        test "serialize('x')":
            var writer = newWriter(newStringStream())
            writer.serialize('x')
            check StringStream(writer.stream).data == "ux"
        test "serialize(\"我\")":
            var writer = newWriter(newStringStream())
            writer.serialize("我")
            check StringStream(writer.stream).data == "u我"
        test "serialize(\"Hello World!\")":
            var writer = newWriter(newStringStream())
            writer.serialize("Hello World!")
            check StringStream(writer.stream).data == "s12\"Hello World!\""
        test "serialize string ref":
            var writer = newWriter(newStringStream())
            var hello = "Hello World!"
            writer.serialize(hello)
            writer.serialize(hello)
            check StringStream(writer.stream).data == "s12\"Hello World!\"r0;"
        test "serialize(\"🇨🇳\")":
            var writer = newWriter(newStringStream())
            writer.serialize("🇨🇳")
            check StringStream(writer.stream).data == "s4\"🇨🇳\""
        test "serialize('\\x80')":
            var writer = newWriter(newStringStream())
            writer.serialize('\x80')
            check StringStream(writer.stream).data == "b1\"\x80\""
        test "serialize(\"\\x80\\x81\")":
            var writer = newWriter(newStringStream())
            writer.serialize("\x80\x81")
            check StringStream(writer.stream).data == "b2\"\x80\x81\""
        test "serialize(\"Hello World!\\x80\\x81\")":
            var writer = newWriter(newStringStream())
            writer.serialize("Hello World!\x80\x81")
            check StringStream(writer.stream).data == "b14\"Hello World!\x80\x81\""
        test "serialize binary string ref":
            var writer = newWriter(newStringStream())
            var data = "Hello World!\x80\x81"
            writer.serialize(data)
            writer.serialize(data)
            check StringStream(writer.stream).data == "b14\"Hello World!\x80\x81\"r0;"
        test "serialize(\"\")":
            var writer = newWriter(newStringStream())
            writer.serialize("")
            check StringStream(writer.stream).data == "e"
        test "serialize(\"2016-03-06\".parse(\"yyyy-MM-dd\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("2016-03-06".parse("yyyy-MM-dd"))
            check StringStream(writer.stream).data == "D20160306;"
        test "serialize(\"2016-03-06 +0\".parse(\"yyyy-MM-dd z\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("2016-03-06 +0".parse("yyyy-MM-dd z"))
            check StringStream(writer.stream).data == "D20160306Z"
        test "serialize(\"1970-01-01 17:32:56\".parse(\"yyyy-MM-dd HH:mm:ss\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("1970-01-01 17:32:56".parse("yyyy-MM-dd HH:mm:ss"))
            check StringStream(writer.stream).data == "T173256;"
        test "serialize(\"1970-01-01 17:32:56 +0\".parse(\"yyyy-MM-dd HH:mm:ss z\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("1970-01-01 17:32:56 +0".parse("yyyy-MM-dd HH:mm:ss z"))
            check StringStream(writer.stream).data == "T173256Z"
        test "serialize(\"2016-03-06 17:32:56\".parse(\"yyyy-MM-dd HH:mm:ss\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("2016-03-06 17:32:56".parse("yyyy-MM-dd HH:mm:ss"))
            check StringStream(writer.stream).data == "D20160306T173256;"
        test "serialize(\"2016-03-06 17:32:56 +0\".parse(\"yyyy-MM-dd HH:mm:ss z\"))":
            var writer = newWriter(newStringStream())
            writer.serialize("2016-03-06 17:32:56 +0".parse("yyyy-MM-dd HH:mm:ss z"))
            check StringStream(writer.stream).data == "D20160306T173256Z"
        test "serialize ptr TimeInfo":
            var writer = newWriter(newStringStream())
            var ti = "2016-03-06 17:32:56 +0".parse("yyyy-MM-dd HH:mm:ss z")
            writer.serialize(ti.addr)
            writer.serialize(ti.addr)
            check StringStream(writer.stream).data == "D20160306T173256Zr0;"
        test "serialize ref TimeInfo":
            var writer = newWriter(newStringStream())
            var ti = "2016-03-06 17:32:56 +0".parse("yyyy-MM-dd HH:mm:ss z")
            writer.serialize(cast[ref TimeInfo](ti.addr))
            writer.serialize(cast[ref TimeInfo](ti.addr))
            check StringStream(writer.stream).data == "D20160306T173256Zr0;"
        test "serialize seq[int]":
            var writer = newWriter(newStringStream())
            var iseq = @[1, 2, 3, 4, 5, 6, 7, 8, 9]
            writer.serialize(iseq)
            writer.serialize(iseq)
            check StringStream(writer.stream).data == "a9{123456789}r0;"
        test "serialize seq[byte]":
            var writer = newWriter(newStringStream())
            var bseq = @[1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8, 8'u8, 9'u8]
            writer.serialize(bseq)
            writer.serialize(bseq)
            check StringStream(writer.stream).data == "b9\"\x01\x02\x03\x04\x05\x06\x07\x08\x09\"r0;"
        test "serialize empty seq[byte]":
            var writer = newWriter(newStringStream())
            var eseq:seq[byte] = @[]
            writer.serialize(eseq)
            writer.serialize(eseq)
            check StringStream(writer.stream).data == "b\"\"r0;"
        test "serialize nil seq[byte]":
            var writer = newWriter(newStringStream())
            var nseq:seq[byte] = nil
            writer.serialize(nseq)
            writer.serialize(nseq)
            check StringStream(writer.stream).data == "nn"
        test "serialize array[int]":
            var writer = newWriter(newStringStream())
            var iarray = [1, 2, 3, 4, 5, 6, 7, 8, 9]
            writer.serialize(iarray)
            writer.serialize(iarray)
            check StringStream(writer.stream).data == "a9{123456789}a9{123456789}"
        test "serialize array[byte]":
            var writer = newWriter(newStringStream())
            var barray = [1'u8, 2'u8, 3'u8, 4'u8, 5'u8, 6'u8, 7'u8, 8'u8, 9'u8]
            writer.serialize(barray)
            writer.serialize(barray)
            check StringStream(writer.stream).data == "b9\"\x01\x02\x03\x04\x05\x06\x07\x08\x09\"b9\"\x01\x02\x03\x04\x05\x06\x07\x08\x09\""
        test "serialize set[int8]":
            var writer = newWriter(newStringStream())
            var iset = {0'i8..9'i8}
            writer.serialize(iset)
            writer.serialize(iset)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize set[byte]":
            var writer = newWriter(newStringStream())
            var bset = {0'u8..9'u8}
            writer.serialize(bset)
            writer.serialize(bset)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize set[char]":
            var writer = newWriter(newStringStream())
            var cset = {'A'..'G'}
            writer.serialize(cset)
            writer.serialize(cset)
            check StringStream(writer.stream).data == "a7{uAuBuCuDuEuFuG}a7{uAuBuCuDuEuFuG}"
        test "serialize ptr set[char]":
            var writer = newWriter(newStringStream())
            var cset = {'A'..'G'}
            writer.serialize(cset.addr)
            writer.serialize(cset.addr)
            check StringStream(writer.stream).data == "a7{uAuBuCuDuEuFuG}r0;"
        test "serialize Queue[int]":
            var writer = newWriter(newStringStream())
            var iqueue = initQueue[int]()
            for i in 0..9: iqueue.add(i)
            writer.serialize(iqueue)
            writer.serialize(iqueue)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize Queue[byte]":
            var writer = newWriter(newStringStream())
            var bqueue = initQueue[byte]()
            for b in 0'u8..9'u8: bqueue.add(b)
            writer.serialize(bqueue)
            writer.serialize(bqueue)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize Queue[char]":
            var writer = newWriter(newStringStream())
            var cqueue = initQueue[char]()
            for c in 'A'..'G': cqueue.add(c)
            writer.serialize(cqueue)
            writer.serialize(cqueue)
            check StringStream(writer.stream).data == "a7{uAuBuCuDuEuFuG}a7{uAuBuCuDuEuFuG}"
        test "serialize ptr Queue[int]":
            var writer = newWriter(newStringStream())
            var iqueue = initQueue[int]()
            for i in 0..9: iqueue.add(i)
            writer.serialize(iqueue.addr)
            writer.serialize(iqueue.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize HashSet[int]":
            var writer = newWriter(newStringStream())
            var iset = initSet[int]()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset)
            writer.serialize(iset)
            check StringStream(writer.stream).data == "a10{1234567890}a10{1234567890}"
        test "serialize HashSet[byte]":
            var writer = newWriter(newStringStream())
            var bset = initSet[byte]()
            for b in 0'u8..9'u8: bset.incl(b)
            writer.serialize(bset)
            writer.serialize(bset)
            check StringStream(writer.stream).data == "a10{1234567890}a10{1234567890}"
        test "serialize HashSet[char]":
            var writer = newWriter(newStringStream())
            var cset = initSet[char]()
            for c in 'A'..'G': cset.incl(c)
            writer.serialize(cset)
            writer.serialize(cset)
            check StringStream(writer.stream).data == "a7{uAuBuCuDuEuFuG}a7{uAuBuCuDuEuFuG}"
        test "serialize ptr HashSet[int]":
            var writer = newWriter(newStringStream())
            var iset = initSet[int]()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset.addr)
            writer.serialize(iset.addr)
            check StringStream(writer.stream).data == "a10{1234567890}r0;"
        test "serialize OrderedSet[int]":
            var writer = newWriter(newStringStream())
            var iset = initOrderedSet[int]()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset)
            writer.serialize(iset)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize OrderedSet[byte]":
            var writer = newWriter(newStringStream())
            var bset = initOrderedSet[byte]()
            for b in 0'u8..9'u8: bset.incl(b)
            writer.serialize(bset)
            writer.serialize(bset)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize OrderedSet[char]":
            var writer = newWriter(newStringStream())
            var cset = initOrderedSet[char]()
            for c in 'A'..'G': cset.incl(c)
            writer.serialize(cset)
            writer.serialize(cset)
            check StringStream(writer.stream).data == "a7{uAuBuCuDuEuFuG}a7{uAuBuCuDuEuFuG}"
        test "serialize ptr OrderedSet[int]":
            var writer = newWriter(newStringStream())
            var iset = initOrderedSet[int]()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset.addr)
            writer.serialize(iset.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize IntSet":
            var writer = newWriter(newStringStream())
            var iset = initIntSet()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset)
            writer.serialize(iset)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize ptr IntSet":
            var writer = newWriter(newStringStream())
            var iset = initIntSet()
            for i in 0..9: iset.incl(i)
            writer.serialize(iset.addr)
            writer.serialize(iset.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize SinglyLinkedList[int]":
            var writer = newWriter(newStringStream())
            var ilist = initSinglyLinkedList[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist)
            writer.serialize(ilist)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize ptr SinglyLinkedList[int]":
            var writer = newWriter(newStringStream())
            var ilist = initSinglyLinkedList[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist.addr)
            writer.serialize(ilist.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize DoublyLinkedList[int]":
            var writer = newWriter(newStringStream())
            var ilist = initDoublyLinkedList[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist)
            writer.serialize(ilist)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize ptr DoublyLinkedList[int]":
            var writer = newWriter(newStringStream())
            var ilist = initDoublyLinkedList[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist.addr)
            writer.serialize(ilist.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize SinglyLinkedRing[int]":
            var writer = newWriter(newStringStream())
            var ilist = initSinglyLinkedRing[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist)
            writer.serialize(ilist)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize ptr SinglyLinkedRing[int]":
            var writer = newWriter(newStringStream())
            var ilist = initSinglyLinkedRing[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist.addr)
            writer.serialize(ilist.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"
        test "serialize DoublyLinkedRing[int]":
            var writer = newWriter(newStringStream())
            var ilist = initDoublyLinkedRing[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist)
            writer.serialize(ilist)
            check StringStream(writer.stream).data == "a10{0123456789}a10{0123456789}"
        test "serialize ptr DoublyLinkedRing[int]":
            var writer = newWriter(newStringStream())
            var ilist = initDoublyLinkedRing[int]()
            for i in countdown(9, 0): ilist.prepend(i)
            writer.serialize(ilist.addr)
            writer.serialize(ilist.addr)
            check StringStream(writer.stream).data == "a10{0123456789}r0;"