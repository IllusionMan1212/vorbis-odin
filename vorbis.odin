package vorbis

import "core:fmt"
import "core:mem"
import "core:os"
import "core:bufio"
import "core:bytes"
import "core:io"
import "core:slice"

VORBIS_MAGIC: u64 : 'v' << 40 | 'o' << 32 | 'r' << 24 | 'b' << 16 | 'i' << 8 | 's'

Error :: union {
	io.Error,
	OggError,
	VorbisError,
}

VorbisError :: enum {
	Invalid_Signature,
	Unsupported_Version,
	Invalid_Channels,
	Invalid_SampleRate,
	Invalid_Blocksize,
	Zero_FramingBit,
}

PacketType :: enum u8 {
	Audio = 0,
	IndentificationHeader = 1,
	CommentsHeader = 3,
	SetupHeader = 5,
	// Reserved types???
}

#assert(size_of(IdentificationHeader) == 23)
IdentificationHeader :: struct #packed {
	vorbis_version: u32,
	channels: u8,
	sample_rate: u32,
	bitrate_max: i32,
	bitrate_nominal: i32,
	bitrate_min: i32,
	blocksize: bit_field u8 {
		_0: u8 | 4,
		_1: u8 | 4,
	},
	framing_flag: bool,
}

CommentsHeader :: struct {
	vendor_name: string,
	comments: []string,
	framing_bit: bool,
}

load_from_file :: proc(path: string, allocator: mem.Allocator) {
	context.allocator = allocator

	data := os.read_entire_file_or_err(path) or_else panic("Failed to read file contents")
	load_from_memory(data, allocator)
}

load_from_file_buffered :: proc(path: string) {
	f := os.open(path) or_else panic("Failed to open file")

	br := new(bufio.Reader)
	bufio.reader_init(br, os.stream_from_handle(f))

	r := new(Reader)
	reader_init(r, bufio.reader_to_stream(br))

	err := decode(r)
	if err != nil {
		fmt.eprintln(err)
	}
}

load_from_memory :: proc(data: []byte, allocator: mem.Allocator) {
	br := new(bytes.Reader)
	s := bytes.reader_init(br, data)

	r := new(Reader)
	reader_init(r, s)

	decode(r)
}

load :: proc{load_from_file, load_from_memory, load_from_file_buffered}

read_identification_header :: proc(r: ^Reader) -> (hdr: IdentificationHeader, err: Error) {
	magic: [6]byte
	read_slice(r, magic[:]) or_return
	magic_d := (cast(^u64be)raw_data(magic[:]))^ >> 16
	if magic_d != cast(u64be)VORBIS_MAGIC {
		return {}, VorbisError.Invalid_Signature
	}

	hdr = read_data(r, IdentificationHeader) or_return

	if hdr.vorbis_version != 0 {
		err = .Unsupported_Version
		return
	}

	if hdr.channels <= 0 {
		err = .Invalid_Channels
		return
	}

	if hdr.sample_rate <= 0 {
		err = .Invalid_SampleRate
		return
	}

	// TODO: check for final blocksize value must be 64, 128, 256, 512, 1024, 2048, 4096 or 8192.
	// Otherwise the stream is undecodable

	if hdr.blocksize._0 > hdr.blocksize._1 {
		err = .Invalid_Blocksize
		return
	}

	if !hdr.framing_flag {
		err = .Zero_FramingBit
		return
	}

	return
}

// TODO: Unlike the first bitstream header packet, this is not generally the only packet on the second page
// of an OGG bitstream, and may not be restricted to within the second bitstream page.
// In plain english: the second page MAY contain both the comments header and the setup header
// and the comment header MAY span multiple pages.
read_comments_header :: proc(r: ^Reader) -> (hdr: CommentsHeader, err: Error) {
	magic: [6]byte
	read_slice(r, magic[:]) or_return
	magic_d := (cast(^u64be)raw_data(magic[:]))^ >> 16
	if magic_d != cast(u64be)VORBIS_MAGIC {
		return {}, VorbisError.Invalid_Signature
	}

	vendor_name_len := read_data(r, u32le) or_return
	vendor_name_slice := make([]byte, vendor_name_len)
	read_slice(r, vendor_name_slice) or_return
	vendor_name := string(vendor_name_slice)

	comments_len := read_data(r, u32le) or_return
	comments := make([]string, comments_len)

	for i in 0..<comments_len {
		comment_len := read_data(r, u32le) or_return
		comment := make([]byte, comment_len)
		read_slice(r, comment)
		comments[i] = string(comment)
	}

	hdr.vendor_name = vendor_name
	hdr.comments = comments
	hdr.framing_bit = cast(bool)read_byte(r) or_return

	// TODO: check for end of packet
	// (requires that we rewrite the decoding process to decode vorbis packets instead of OGG pages)
	// Errors in comments header are non-fatal
	if !hdr.framing_bit /* || end-of-packet */ {
		fmt.eprintln("Framing bit is unset or reached end of packet.")
	}

	return
}

read_vorbis_packet :: proc(r: ^Reader) -> Error {
	// TODO: packet type might not be present for the audio packets. double check
	packet_type := cast(PacketType)read_byte(r) or_return

	switch packet_type {
	case .IndentificationHeader:
		ident_header := read_identification_header(r) or_return
		fmt.println(ident_header)

		// Bitrate fields are only hints.
		// Fields are only meaningful when greater than 0
		// All three fields set to the same value implies a fixed-rate or nearly fixed-rate bitstream
		// Only nominal implies a VBR or ABR stream
		// Max and or Min set implies a VBR bitstream that obeys the bitrate limits
		// None set indicates the encoder does not care to speculate
	case .CommentsHeader:
		comments_header := read_comments_header(r) or_return
		fmt.println(comments_header)
	case .SetupHeader:
		fmt.println(packet_type)
		panic("Found setup header packet")
	case .Audio:
		fmt.println(packet_type)
		// panic("Found audio packet")
	}

	return nil
}

// TODO: move to ogg.odin (this will also get rewritten anyway)
read_page :: proc(r: ^Reader) -> (page: Page, err: Error) {
	header := read_data(r, PageHeader) or_return

	if header.magic != OGG_MAGIC {
		return {}, OggError.Invalid_Signature
	}

	segment_table := make([]byte, header.page_segments)
	read_slice(r, segment_table) or_return

	packet_size := 0
	for lacing_val in segment_table {
		packet_size += int(lacing_val)
	}

	packet := make([]byte, packet_size)
	read_slice(r, packet) or_return

	br: bytes.Reader
	vorbis_r := &Reader{
		r = bytes.reader_init(&br, packet),
		buf = r.buf,
		x = r.x,
		n = r.n
	}

	read_vorbis_packet(vorbis_r) or_return

	expected_crc := header.page_checksum
	header.page_checksum = 0
	header_slice := slice.bytes_from_ptr(&header, size_of(PageHeader))

	page_bytes := bytes.join({header_slice, segment_table, packet}, {})
	defer delete(page_bytes)
	calculated_crc := page_checksum(page_bytes)
	if calculated_crc != expected_crc {
		fmt.eprintfln("Expected page CRC: 0x%X, got: 0x%X", expected_crc, calculated_crc)
		return {}, .CRC_Mismatch
	}

	header.page_checksum = expected_crc

	return { header = header, lacing_values = segment_table, data = packet }, nil
}

@(private)
decode :: proc(r: ^Reader) -> Error {
	for {
		// TODO: we should decode vorbis packets here (packet by packet in a loop) instead of OGG pages.
		// and inside the vorbis-packet-decoding proc we read OGG pages if we must until we finish the packet
		// we should also be able to resume reading from the same OGG page if there's still data available in it.
		page := read_page(r) or_return
		// TODO: implement continued packets
		assert(!page.header.header_type_flag.is_continued_packet)

		//fmt.println(page.header)
	}

	return nil
}

destroy :: proc(r: ^Reader) {
	// TODO:
}
