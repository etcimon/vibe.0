/* Copyright 2013 Google Inc. All Rights Reserved.

   Distributed under MIT license.
   See file LICENSE for detail or copy at https://opensource.org/licenses/MIT
*/

module vibe.data.brotli;

extern(C):
/**
 * @file
 * API for Brotli decompression.
 */
/**
 * A portable @c bool replacement.
 *
 * ::BROTLI_BOOL is a "documentation" type: actually it is @c int, but in API it
 * denotes a type, whose only values are ::BROTLI_TRUE and ::BROTLI_FALSE.
 *
 * ::BROTLI_BOOL values passed to Brotli should either be ::BROTLI_TRUE or
 * ::BROTLI_FALSE, or be a result of ::TO_BROTLI_BOOL macros.
 *
 * ::BROTLI_BOOL values returned by Brotli should not be tested for equality
 * with @c true, @c false, ::BROTLI_TRUE, ::BROTLI_FALSE, but rather should be
 * evaluated, for example: @code{.cpp}
 * if (SomeBrotliFunction(encoder, BROTLI_TRUE) &&
 *     !OtherBrotliFunction(decoder, BROTLI_FALSE)) {
 *   bool x = !!YetAnotherBrotliFunction(encoder, TO_BROLTI_BOOL(2 * 2 == 4));
 *   DoSomething(x);
 * }
 * @endcode
 */
alias BROTLI_BOOL = int;
/** Portable @c true replacement. */
enum BROTLI_TRUE = 1;
/** Portable @c false replacement. */
enum BROTLI_FALSE = 0;
/** @c bool to ::BROTLI_BOOL conversion macros. */
BROTLI_BOOL TO_BROTLI_BOOL(T)(T X) {
	if (X)
		return BROTLI_TRUE;
	else return BROTLI_FALSE;
}

ulong BROTLI_MAKE_UINT64_T(T, U)(T high, U low) {
	return (((cast(ulong)(high)) << 32) | low);
}
uint BROTLI_UINT32_MAX() {
	return (~(cast(uint)0));
}
size_t BROTLI_SIZE_MAX() {
	return (~(cast(size_t)0));
}
/**
 * Allocating function pointer type.
 *
 * @param opaque custom memory manager handle provided by client
 * @param size requested memory region size; can not be @c 0
 * @returns @c 0 in the case of failure
 * @returns a valid pointer to a memory region of at least @p size bytes
 *          long otherwise
 */
alias brotli_alloc_func = void* function(void* opaque, size_t size);

/**
 * Deallocating function pointer type.
 *
 * This function @b SHOULD do nothing if @p address is @c 0.
 *
 * @param opaque custom memory manager handle provided by client
 * @param address memory region pointer returned by ::brotli_alloc_func, or @c 0
 */
alias brotli_free_func = void function(void* opaque, void* address);
alias BROTLI_ARRAY_PARAM(L) = L;

/**
 * Opaque structure that holds decoder state.
 *
 * Allocated and initialized with ::BrotliDecoderCreateInstance.
 * Cleaned up and deallocated with ::BrotliDecoderDestroyInstance.
 */
struct BrotliDecoderState {}

/**
 * Result type for ::BrotliDecoderDecompress and
 * ::BrotliDecoderDecompressStream functions.
 */
enum BrotliDecoderResult : int{
  /** Decoding error, e.g. corrupted input or memory allocation problem. */
  BROTLI_DECODER_RESULT_ERROR = 0,
  /** Decoding successfully completed */
  BROTLI_DECODER_RESULT_SUCCESS = 1,
  /** Partially done; should be called again with more input */
  BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT = 2,
  /** Partially done; should be called again with more output */
  BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT = 3
}
alias BrotliDecoderErrorCode = int;
enum {
  NO_ERROR = 0,
  /* Same as BrotliDecoderResult values */
  SUCCESS = 1,
  NEEDS_MORE_INPUT = 2,
  NEEDS_MORE_OUTPUT = 3,

  /* Errors caused by invalid input */ 
  EXUBERANT_NIBBLE = -1,
  RESERVED = -2,
  EXUBERANT_META_NIBBLE = -3,
  SIMPLE_HUFFMAN_ALPHABET = -4,
  SIMPLE_HUFFMAN_SAME = -5,
  CL_SPACE = -6,
  HUFFMAN_SPACE = -7,
  CONTEXT_MAP_REPEAT = -8,
  BLOCK_LENGTH_1 = -9,
  BLOCK_LENGTH_2 = -10,
  TRANSFORM = -11,
  DICTIONARY = -12,
  WINDOW_BITS = -13,
  PADDING_1 = -14,
  PADDING_2 = -15,
  
  /* -16..-18 codes are reserved */
  
  DICTIONARY_NOT_SET = -19,
  INVALID_ARGUMENTS = -20,
  
  /* Memory allocation problems */
  CONTEXT_MODES = -21,
  /* Literal, insert and distance trees together */
  TREE_GROUPS = -22,
  /* -23..-24 codes are reserved for distinct tree groups */
  CONTEXT_MAP = -25,
  RING_BUFFER_1 = -26,
  RING_BUFFER_2 = -27,
  /* -28..-29 codes are reserved for dynamic ring-buffer allocation */
  BLOCK_TYPE_TREES = -30,
  
  /* "Impossible" states */ 
  UNREACHABLE = -31,
  
}

/**
 * The value of the last error code, negative integer.
 *
 * All other error code values are in the range from ::BROTLI_LAST_ERROR_CODE
 * to @c -1. There are also 4 other possible non-error codes @c 0 .. @c 3 in
 * ::BrotliDecoderErrorCode enumeration.
 */
enum BROTLI_LAST_ERROR_CODE = UNREACHABLE;

/** Options to be used with ::BrotliDecoderSetParameter. */
enum BrotliDecoderParameter : int {
  /**
   * Disable "canny" ring buffer allocation strategy.
   *
   * Ring buffer is allocated according to window size, despite the real size of
   * the content.
   */
  BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION = 0
}

/**
 * Sets the specified parameter to the given decoder instance.
 *
 * @param state decoder instance
 * @param param parameter to set
 * @param value new parameter value
 * @returns ::BROTLI_FALSE if parameter is unrecognized, or value is invalid
 * @returns ::BROTLI_TRUE if value is accepted
 */
BROTLI_BOOL BrotliDecoderSetParameter(
    BrotliDecoderState* state, BrotliDecoderParameter param, uint value);

/**
 * Creates an instance of ::BrotliDecoderState and initializes it.
 *
 * The instance can be used once for decoding and should then be destroyed with
 * ::BrotliDecoderDestroyInstance, it cannot be reused for a new decoding
 * session.
 *
 * @p alloc_func and @p free_func @b MUST be both zero or both non-zero. In the
 * case they are both zero, default memory allocators are used. @p opaque is
 * passed to @p alloc_func and @p free_func when they are called.
 *
 * @param alloc_func custom memory allocation function
 * @param free_func custom memory fee function
 * @param opaque custom memory manager handle
 * @returns @c 0 if instance can not be allocated or initialized
 * @returns pointer to initialized ::BrotliDecoderState otherwise
 */
BrotliDecoderState* BrotliDecoderCreateInstance(
    brotli_alloc_func alloc_func, brotli_free_func free_func, void* opaque);

/**
 * Deinitializes and frees ::BrotliDecoderState instance.
 *
 * @param state decoder instance to be cleaned up and deallocated
 */
void BrotliDecoderDestroyInstance(BrotliDecoderState* state);

/**
 * Performs one-shot memory-to-memory decompression.
 *
 * Decompresses the data in @p encoded_buffer into @p decoded_buffer, and sets
 * @p *decoded_size to the decompressed length.
 *
 * @param encoded_size size of @p encoded_buffer
 * @param encoded_buffer compressed data buffer with at least @p encoded_size
 *        addressable bytes
 * @param[in, out] decoded_size @b in: size of @p decoded_buffer; \n
 *                 @b out: length of decompressed data written to
 *                 @p decoded_buffer
 * @param decoded_buffer decompressed data destination buffer
 * @returns ::BROTLI_DECODER_RESULT_ERROR if input is corrupted, memory
 *          allocation failed, or @p decoded_buffer is not large enough;
 * @returns ::BROTLI_DECODER_RESULT_SUCCESS otherwise
 */
BrotliDecoderResult BrotliDecoderDecompress(
    size_t encoded_size,
    const(ubyte)* encoded_buffer,
    size_t* decoded_size,
    ubyte* decoded_buffer);

/**
 * Decompresses the input stream to the output stream.
 *
 * The values @p *available_in and @p *available_out must specify the number of
 * bytes addressable at @p *next_in and @p *next_out respectively.
 * When @p *available_out is @c 0, @p next_out is allowed to be @c NULL.
 *
 * After each call, @p *available_in will be decremented by the amount of input
 * bytes consumed, and the @p *next_in pointer will be incremented by that
 * amount. Similarly, @p *available_out will be decremented by the amount of
 * output bytes written, and the @p *next_out pointer will be incremented by
 * that amount.
 *
 * @p total_out, if it is not a null-pointer, will be set to the number
 * of bytes decompressed since the last @p state initialization.
 *
 * @note Input is never overconsumed, so @p next_in and @p available_in could be
 * passed to the next consumer after decoding is complete.
 *
 * @param state decoder instance
 * @param[in, out] available_in @b in: amount of available input; \n
 *                 @b out: amount of unused input
 * @param[in, out] next_in pointer to the next compressed byte
 * @param[in, out] available_out @b in: length of output buffer; \n
 *                 @b out: remaining size of output buffer
 * @param[in, out] next_out output buffer cursor;
 *                 can be @c NULL if @p available_out is @c 0
 * @param[out] total_out number of bytes decompressed so far; can be @c NULL
 * @returns ::BROTLI_DECODER_RESULT_ERROR if input is corrupted, memory
 *          allocation failed, arguments were invalid, etc.;
 *          use ::BrotliDecoderGetErrorCode to get detailed error code
 * @returns ::BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT decoding is blocked until
 *          more input data is provided
 * @returns ::BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT decoding is blocked until
 *          more output space is provided
 * @returns ::BROTLI_DECODER_RESULT_SUCCESS decoding is finished, no more
 *          input might be consumed and no more output will be produced
 */
BrotliDecoderResult BrotliDecoderDecompressStream(
  BrotliDecoderState* state, size_t* available_in, const(ubyte)** next_in,
  size_t* available_out, ubyte** next_out, size_t* total_out);

/**
 * Prepends LZ77 dictionary.
 *
 * Fills the fresh ::BrotliDecoderState with additional data corpus for LZ77
 * backward references.
 *
 * @note Not to be confused with the static dictionary (see RFC7932 section 8).
 * @warning The dictionary must exist in memory until decoding is done and
 *          is owned by the caller.
 *
 * Workflow:
 *  -# Allocate and initialize state with ::BrotliDecoderCreateInstance
 *  -# Invoke ::BrotliDecoderSetCustomDictionary
 *  -# Use ::BrotliDecoderDecompressStream
 *  -# Clean up and free state with ::BrotliDecoderDestroyInstance
 *
 * @param state decoder instance
 * @param size length of @p dict; should be less or equal to 2^24 (16MiB),
 *        otherwise the dictionary will be ignored
 * @param dict "dictionary"; @b MUST be the same as used during compression
 */
void BrotliDecoderSetCustomDictionary(
    BrotliDecoderState* state, size_t size,
    const(ubyte)* dict);

/**
 * Checks if decoder has more output.
 *
 * @param state decoder instance
 * @returns ::BROTLI_TRUE, if decoder has some unconsumed output
 * @returns ::BROTLI_FALSE otherwise
 */
BROTLI_BOOL BrotliDecoderHasMoreOutput(
    const BrotliDecoderState* state);

/**
 * Acquires pointer to internal output buffer.
 *
 * This method is used to make language bindings easier and more efficient:
 *  -# push data to ::BrotliDecoderDecompressStream,
 *     until ::BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT is reported
 *  -# use ::BrotliDecoderTakeOutput to peek bytes and copy to language-specific
 *     entity
 *
 * Also this could be useful if there is an output stream that is able to
 * consume all the provided data (e.g. when data is saved to file system).
 *
 * @attention After every call to ::BrotliDecoderTakeOutput @p *size bytes of
 *            output are considered consumed for all consecutive calls to the
 *            instance methods; returned pointer becomes invalidated as well.
 *
 * @note Decoder output is not guaranteed to be contiguous. This means that
 *       after the size-unrestricted call to ::BrotliDecoderTakeOutput,
 *       immediate next call to ::BrotliDecoderTakeOutput may return more data.
 *
 * @param state decoder instance
 * @param[in, out] size @b in: number of bytes caller is ready to take, @c 0 if
 *                 any amount could be handled; \n
 *                 @b out: amount of data pointed by returned pointer and
 *                 considered consumed; \n
 *                 out value is never greater than in value, unless it is @c 0
 * @returns pointer to output data
 */
const(ubyte)* BrotliDecoderTakeOutput(BrotliDecoderState* state, size_t* size);

/**
 * Checks if instance has already consumed input.
 *
 * Instance that returns ::BROTLI_FALSE is considered "fresh" and could be
 * reused.
 *
 * @param state decoder instance
 * @returns ::BROTLI_TRUE if decoder has already used some input bytes
 * @returns ::BROTLI_FALSE otherwise
 */
BROTLI_BOOL BrotliDecoderIsUsed(const(BrotliDecoderState)* state);

/**
 * Checks if decoder instance reached the final state.
 *
 * @param state decoder instance
 * @returns ::BROTLI_TRUE if decoder is in a state where it reached the end of
 *          the input and produced all of the output
 * @returns ::BROTLI_FALSE otherwise
 */
BROTLI_BOOL BrotliDecoderIsFinished(const(BrotliDecoderState)* state);

/**
 * Acquires a detailed error code.
 *
 * Should be used only after ::BrotliDecoderDecompressStream returns
 * ::BROTLI_DECODER_RESULT_ERROR.
 *
 * See also ::BrotliDecoderErrorString
 *
 * @param state decoder instance
 * @returns last saved error code
 */
BrotliDecoderErrorCode BrotliDecoderGetErrorCode(
    const BrotliDecoderState* state);

/**
 * Converts error code to a c-string.
 */
const(char)* BrotliDecoderErrorString(BrotliDecoderErrorCode c);

/**
 * Gets a decoder library version.
 *
 * Look at BROTLI_VERSION for more information.
 */
uint BrotliDecoderVersion();


/**
 * @file
 * API for Brotli compression.
 */

/** Minimal value for ::BROTLI_PARAM_LGWIN parameter. */
enum BROTLI_MIN_WINDOW_BITS = 10;
/**
 * Maximal value for ::BROTLI_PARAM_LGWIN parameter.
 *
 * @note equal to @c BROTLI_MAX_DISTANCE_BITS constant.
 */
enum BROTLI_MAX_WINDOW_BITS = 24;
/** Minimal value for ::BROTLI_PARAM_LGBLOCK parameter. */
enum BROTLI_MIN_INPUT_BLOCK_BITS = 16;
/** Maximal value for ::BROTLI_PARAM_LGBLOCK parameter. */
enum BROTLI_MAX_INPUT_BLOCK_BITS = 24;
/** Minimal value for ::BROTLI_PARAM_QUALITY parameter. */
enum BROTLI_MIN_QUALITY = 0;
/** Maximal value for ::BROTLI_PARAM_QUALITY parameter. */
enum BROTLI_MAX_QUALITY = 11;
alias BrotliEncoderMode = int;
/** Options for ::BROTLI_PARAM_MODE parameter. */
enum {
  /**
   * Default compression mode.
   *
   * In this mode compressor does not know anything in advance about the
   * properties of the input.
   */
  BROTLI_MODE_GENERIC = 0,
  /** Compression mode for UTF-8 formatted text input. */
  BROTLI_MODE_TEXT = 1,
  /** Compression mode used in WOFF 2.0. */
  BROTLI_MODE_FONT = 2
}

/** Default value for ::BROTLI_PARAM_QUALITY parameter. */
enum BROTLI_DEFAULT_QUALITY = 11;
/** Default value for ::BROTLI_PARAM_LGWIN parameter. */
enum BROTLI_DEFAULT_WINDOW = 22;
/** Default value for ::BROTLI_PARAM_MODE parameter. */
enum BROTLI_DEFAULT_MODE = BROTLI_MODE_GENERIC;

/** Operations that can be performed by streaming encoder. */
enum BrotliEncoderOperation : int {
  /**
   * Process input.
   *
   * Encoder may postpone producing output, until it has processed enough input.
   */
  BROTLI_OPERATION_PROCESS = 0,
  /**
   * Produce output for all processed input.
   *
   * Actual flush is performed when input stream is depleted and there is enough
   * space in output stream. This means that client should repeat
   * ::BROTLI_OPERATION_FLUSH operation until @p available_in becomes @c 0, and
   * ::BrotliEncoderHasMoreOutput returns ::BROTLI_FALSE.
   *
   * @warning Until flush is complete, client @b SHOULD @b NOT swap,
   *          reduce or extend input stream.
   *
   * When flush is complete, output data will be sufficient for decoder to
   * reproduce all the given input.
   */
  BROTLI_OPERATION_FLUSH = 1,
  /**
   * Finalize the stream.
   *
   * Actual finalization is performed when input stream is depleted and there is
   * enough space in output stream. This means that client should repeat
   * ::BROTLI_OPERATION_FLUSH operation until @p available_in becomes @c 0, and
   * ::BrotliEncoderHasMoreOutput returns ::BROTLI_FALSE.
   *
   * @warning Until finalization is complete, client @b SHOULD @b NOT swap,
   *          reduce or extend input stream.
   *
   * Helper function ::BrotliEncoderIsFinished checks if stream is finalized and
   * output fully dumped.
   *
   * Adding more input data to finalized stream is impossible.
   */
  BROTLI_OPERATION_FINISH = 2,
  /**
   * Emit metadata block to stream.
   *
   * Metadata is opaque to Brotli: neither encoder, nor decoder processes this
   * data or relies on it. It may be used to pass some extra information from
   * encoder client to decoder client without interfering with main data stream.
   *
   * @note Encoder may emit empty metadata blocks internally, to pad encoded
   *       stream to byte boundary.
   *
   * @warning Until emitting metadata is complete client @b SHOULD @b NOT swap,
   *          reduce or extend input stream.
   *
   * @warning The whole content of input buffer is considered to be the content
   *          of metadata block. Do @b NOT @e append metadata to input stream,
   *          before it is depleted with other operations.
   *
   * Stream is soft-flushed before metadata block is emitted. Metadata block
   * @b MUST be no longer than than 16MiB.
   */
  BROTLI_OPERATION_EMIT_METADATA = 3
}

/** Options to be used with ::BrotliEncoderSetParameter. */
enum BrotliEncoderParameter : int {
  /**
   * Tune encoder for specific input.
   *
   * ::BrotliEncoderMode enumerates all available values.
   */
  BROTLI_PARAM_MODE = 0,
  /**
   * The main compression speed-density lever.
   *
   * The higher the quality, the slower the compression. Range is
   * from ::BROTLI_MIN_QUALITY to ::BROTLI_MAX_QUALITY.
   */
  BROTLI_PARAM_QUALITY = 1,
  /**
   * Recommended sliding LZ77 window size.
   *
   * Encoder may reduce this value, e.g. if input is much smaller than
   * window size.
   *
   * Window size is `(1 << value) - 16`.
   *
   * Range is from ::BROTLI_MIN_WINDOW_BITS to ::BROTLI_MAX_WINDOW_BITS.
   */
  BROTLI_PARAM_LGWIN = 2,
  /**
   * Recommended input block size.
   *
   * Encoder may reduce this value, e.g. if input is much smaller than input
   * block size.
   *
   * Range is from ::BROTLI_MIN_INPUT_BLOCK_BITS to
   * ::BROTLI_MAX_INPUT_BLOCK_BITS.
   *
   * @note Bigger input block size allows better compression, but consumes more
   *       memory. \n The rough formula of memory used for temporary input
   *       storage is `3 << lgBlock`.
   */
  BROTLI_PARAM_LGBLOCK = 3,
  /**
   * Flag that affects usage of "literal context modeling" format feature.
   *
   * This flag is a "decoding-speed vs compression ratio" trade-off.
   */
  BROTLI_PARAM_DISABLE_LITERAL_CONTEXT_MODELING = 4,
  /**
   * Estimated total input size for all ::BrotliEncoderCompressStream calls.
   *
   * The default value is 0, which means that the total input size is unknown.
   */
  BROTLI_PARAM_SIZE_HINT = 5
}

/**
 * Opaque structure that holds encoder state.
 *
 * Allocated and initialized with ::BrotliEncoderCreateInstance.
 * Cleaned up and deallocated with ::BrotliEncoderDestroyInstance.
 */
struct BrotliEncoderState { }

/**
 * Sets the specified parameter to the given encoder instance.
 *
 * @param state encoder instance
 * @param param parameter to set
 * @param value new parameter value
 * @returns ::BROTLI_FALSE if parameter is unrecognized, or value is invalid
 * @returns ::BROTLI_FALSE if value of parameter can not be changed at current
 *          encoder state (e.g. when encoding is started, window size might be
 *          already encoded and therefore it is impossible to change it)
 * @returns ::BROTLI_TRUE if value is accepted
 * @warning invalid values might be accepted in case they would not break
 *          encoding process.
 */
BROTLI_BOOL BrotliEncoderSetParameter(
    BrotliEncoderState* state, BrotliEncoderParameter param, uint value);

/**
 * Creates an instance of ::BrotliEncoderState and initializes it.
 *
 * @p alloc_func and @p free_func @b MUST be both zero or both non-zero. In the
 * case they are both zero, default memory allocators are used. @p opaque is
 * passed to @p alloc_func and @p free_func when they are called.
 *
 * @param alloc_func custom memory allocation function
 * @param free_func custom memory fee function
 * @param opaque custom memory manager handle
 * @returns @c 0 if instance can not be allocated or initialized
 * @returns pointer to initialized ::BrotliEncoderState otherwise
 */
BrotliEncoderState* BrotliEncoderCreateInstance(
    brotli_alloc_func alloc_func, brotli_free_func free_func, void* opaque);

/**
 * Deinitializes and frees ::BrotliEncoderState instance.
 *
 * @param state decoder instance to be cleaned up and deallocated
 */
void BrotliEncoderDestroyInstance(BrotliEncoderState* state);

/**
 * Prepends imaginary LZ77 dictionary.
 *
 * Fills the fresh ::BrotliEncoderState with additional data corpus for LZ77
 * backward references.
 *
 * @note Not to be confused with the static dictionary (see RFC7932 section 8).
 *
 * Workflow:
 *  -# Allocate and initialize state with ::BrotliEncoderCreateInstance
 *  -# Set ::BROTLI_PARAM_LGWIN parameter
 *  -# Invoke ::BrotliEncoderSetCustomDictionary
 *  -# Use ::BrotliEncoderCompressStream
 *  -# Clean up and free state with ::BrotliEncoderDestroyInstance
 *
 * @param state encoder instance
 * @param size length of @p dict; at most "window size" bytes are used
 * @param dict "dictionary"; @b MUST use same dictionary during decompression
 */
void BrotliEncoderSetCustomDictionary(
    BrotliEncoderState* state, size_t size,
    const(ubyte)* dict);

/**
 * Calculates the output size bound for the given @p input_size.
 *
 * @warning Result is not applicable to ::BrotliEncoderCompressStream output,
 *          because every "flush" adds extra overhead bytes, and some encoder
 *          settings (e.g. quality @c 0 and @c 1) might imply a "soft flush"
 *          after every chunk of input.
 *
 * @param input_size size of projected input
 * @returns @c 0 if result does not fit @c size_t
 */
size_t BrotliEncoderMaxCompressedSize(size_t input_size);

/**
 * Performs one-shot memory-to-memory compression.
 *
 * Compresses the data in @p input_buffer into @p encoded_buffer, and sets
 * @p *encoded_size to the compressed length.
 *
 * @note If ::BrotliEncoderMaxCompressedSize(@p input_size) returns non-zero
 *       value, then output is guaranteed to be no longer than that.
 *
 * @param quality quality parameter value, e.g. ::BROTLI_DEFAULT_QUALITY
 * @param lgwin lgwin parameter value, e.g. ::BROTLI_DEFAULT_WINDOW
 * @param mode mode parameter value, e.g. ::BROTLI_DEFAULT_MODE
 * @param input_size size of @p input_buffer
 * @param input_buffer input data buffer with at least @p input_size
 *        addressable bytes
 * @param[in, out] encoded_size @b in: size of @p encoded_buffer; \n
 *                 @b out: length of compressed data written to
 *                 @p encoded_buffer, or @c 0 if compression fails
 * @param encoded_buffer compressed data destination buffer
 * @returns ::BROTLI_FALSE in case of compression error
 * @returns ::BROTLI_FALSE if output buffer is too small
 * @returns ::BROTLI_TRUE otherwise
 */
BROTLI_BOOL BrotliEncoderCompress(
    int quality, int lgwin, BrotliEncoderMode mode, size_t input_size,
    const(ubyte)* input_buffer,
    size_t* encoded_size,
    ubyte* encoded_buffer);

/**
 * Compresses input stream to output stream.
 *
 * The values @p *available_in and @p *available_out must specify the number of
 * bytes addressable at @p *next_in and @p *next_out respectively.
 * When @p *available_out is @c 0, @p next_out is allowed to be @c NULL.
 *
 * After each call, @p *available_in will be decremented by the amount of input
 * bytes consumed, and the @p *next_in pointer will be incremented by that
 * amount. Similarly, @p *available_out will be decremented by the amount of
 * output bytes written, and the @p *next_out pointer will be incremented by
 * that amount.
 *
 * @p total_out, if it is not a null-pointer, will be set to the number
 * of bytes decompressed since the last @p state initialization.
 *
 *
 *
 * Internally workflow consists of 3 tasks:
 *  -# (optionally) copy input data to internal buffer
 *  -# actually compress data and (optionally) store it to internal buffer
 *  -# (optionally) copy compressed bytes from internal buffer to output stream
 *
 * Whenever all 3 tasks can't move forward anymore, or error occurs, this
 * method returns the control flow to caller.
 *
 * @p op is used to perform flush, finish the stream, or inject metadata block.
 * See ::BrotliEncoderOperation for more information.
 *
 * Flushing the stream means forcing encoding of all input passed to encoder and
 * completing the current output block, so it could be fully decoded by stream
 * decoder. To perform flush set @p op to ::BROTLI_OPERATION_FLUSH.
 * Under some circumstances (e.g. lack of output stream capacity) this operation
 * would require several calls to ::BrotliEncoderCompressStream. The method must
 * be called again until both input stream is depleted and encoder has no more
 * output (see ::BrotliEncoderHasMoreOutput) after the method is called.
 *
 * Finishing the stream means encoding of all input passed to encoder and
 * adding specific "final" marks, so stream decoder could determine that stream
 * is complete. To perform finish set @p op to ::BROTLI_OPERATION_FINISH.
 * Under some circumstances (e.g. lack of output stream capacity) this operation
 * would require several calls to ::BrotliEncoderCompressStream. The method must
 * be called again until both input stream is depleted and encoder has no more
 * output (see ::BrotliEncoderHasMoreOutput) after the method is called.
 *
 * @warning When flushing and finishing, @p op should not change until operation
 *          is complete; input stream should not be swapped, reduced or
 *          extended as well.
 *
 * @param state encoder instance
 * @param op requested operation
 * @param[in, out] available_in @b in: amount of available input; \n
 *                 @b out: amount of unused input
 * @param[in, out] next_in pointer to the next input byte
 * @param[in, out] available_out @b in: length of output buffer; \n
 *                 @b out: remaining size of output buffer
 * @param[in, out] next_out compressed output buffer cursor;
 *                 can be @c NULL if @p available_out is @c 0
 * @param[out] total_out number of bytes produced so far; can be @c NULL
 * @returns ::BROTLI_FALSE if there was an error
 * @returns ::BROTLI_TRUE otherwise
 */
BROTLI_BOOL BrotliEncoderCompressStream(
    BrotliEncoderState* state, BrotliEncoderOperation op, size_t* available_in,
    const(ubyte)** next_in, size_t* available_out, ubyte** next_out,
    size_t* total_out);

/**
 * Checks if encoder instance reached the final state.
 *
 * @param state encoder instance
 * @returns ::BROTLI_TRUE if encoder is in a state where it reached the end of
 *          the input and produced all of the output
 * @returns ::BROTLI_FALSE otherwise
 */
BROTLI_BOOL BrotliEncoderIsFinished(BrotliEncoderState* state);

/**
 * Checks if encoder has more output.
 *
 * @param state encoder instance
 * @returns ::BROTLI_TRUE, if encoder has some unconsumed output
 * @returns ::BROTLI_FALSE otherwise
 */
BROTLI_BOOL BrotliEncoderHasMoreOutput(
    BrotliEncoderState* state);

/**
 * Acquires pointer to internal output buffer.
 *
 * This method is used to make language bindings easier and more efficient:
 *  -# push data to ::BrotliEncoderCompressStream,
 *     until ::BrotliEncoderHasMoreOutput returns BROTL_TRUE
 *  -# use ::BrotliEncoderTakeOutput to peek bytes and copy to language-specific
 *     entity
 *
 * Also this could be useful if there is an output stream that is able to
 * consume all the provided data (e.g. when data is saved to file system).
 *
 * @attention After every call to ::BrotliEncoderTakeOutput @p *size bytes of
 *            output are considered consumed for all consecutive calls to the
 *            instance methods; returned pointer becomes invalidated as well.
 *
 * @note Encoder output is not guaranteed to be contiguous. This means that
 *       after the size-unrestricted call to ::BrotliEncoderTakeOutput,
 *       immediate next call to ::BrotliEncoderTakeOutput may return more data.
 *
 * @param state encoder instance
 * @param[in, out] size @b in: number of bytes caller is ready to take, @c 0 if
 *                 any amount could be handled; \n
 *                 @b out: amount of data pointed by returned pointer and
 *                 considered consumed; \n
 *                 out value is never greater than in value, unless it is @c 0
 * @returns pointer to output data
 */
const(ubyte)* BrotliEncoderTakeOutput(
    BrotliEncoderState* state, size_t* size);


/**
 * Gets an encoder library version.
 *
 * Look at BROTLI_VERSION for more information.
 */
uint BrotliEncoderVersion();
