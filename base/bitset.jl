# This file is a part of Julia. License is MIT: https://julialang.org/license

const Bits = Vector{UInt64}
const CHK0 = zero(UInt64)
const NO_OFFSET = Int === Int64 ? -one(Int) << 60 : -one(Int) << 29
# + NO_OFFSET must be small enough to stay < 0 when added with any offset.
#   An offset is in the range -2^57:2^57 (64-bits architectures)
#   or -2^26:2^26 (32-bits architectures)
# + when the offset is NO_OFFSET, the bits field *must* be empty
# + NO_OFFSET could be made to be > 0, but a negative one allows
#   a small optimization in the in(x, ::BitSet) method

mutable struct BitSet <: AbstractSet{Int}
    const bits::Vector{UInt64}
    # 1st stored Int equals 64*offset
    offset::Int

    BitSet() = new(sizehint!(zeros(UInt64, 0), 4), NO_OFFSET)
end

"""
    BitSet([itr])

Construct a sorted set of `Int`s generated by the given iterable object, or an
empty set. Implemented as a bit string, and therefore designed for dense integer sets.
If the set will be sparse (for example, holding a few
very large integers), use [`Set`](@ref) instead.
"""
BitSet(itr) = union!(BitSet(), itr)

# Special implementation for BitSet, which lacks a fast `length` method.
function union!(s::BitSet, itr)
    for x in itr
        push!(s, x)
    end
    return s
end

@inline intoffset(s::BitSet) = s.offset << 6

eltype(::Type{BitSet}) = Int

empty(s::BitSet, ::Type{Int}=Int) = BitSet()
emptymutable(s::BitSet, ::Type{Int}=Int) = BitSet()

copy(s1::BitSet) = copy!(BitSet(), s1)
copymutable(s::BitSet) = copy(s)

function copy!(dest::BitSet, src::BitSet)
    resize!(dest.bits, length(src.bits))
    copyto!(dest.bits, src.bits)
    dest.offset = src.offset
    dest
end

sizehint!(s::BitSet, n::Integer) = (sizehint!(s.bits, (n+63) >> 6); s)

function _bits_getindex(b::Bits, n::Int, offset::Int)
    ci = _div64(n) - offset + 1
    1 <= ci <= length(b) || return false
    @inbounds r = (b[ci] & (one(UInt64) << _mod64(n))) != 0
    r
end

function _bits_findnext(b::Bits, start::Int)
    # start is 0-based
    # @assert start >= 0
    _div64(start) + 1 > length(b) && return -1
    ind = unsafe_bitfindnext(b, start+1)
    ind === nothing ? -1 : ind - 1
end

function _bits_findprev(b::Bits, start::Int)
    # start is 0-based
    # @assert start <= 64 * length(b) - 1
    start >= 0 || return -1
    ind = unsafe_bitfindprev(b, start+1)
    ind === nothing ? -1 : ind - 1
end

# An internal function for setting the inclusion bit for a given integer
@inline function _setint!(s::BitSet, idx::Int, b::Bool)
    cidx = _div64(idx)
    len = length(s.bits)
    diff = cidx - s.offset
    if diff >= len
        b || return s # setting a bit to zero outside the set's bits is a no-op

        # we put the following test within one of the two branches,
        # with the NO_OFFSET trick, to avoid having to perform it at
        # each and every call to _setint!
        if s.offset == NO_OFFSET # initialize the offset
            # we assume isempty(s.bits)
            s.offset = cidx
            diff = 0
        end
        _growend0!(s.bits, diff - len + 1)
    elseif diff < 0
        b || return s
        _growbeg0!(s.bits, -diff)
        s.offset += diff
        diff = 0
    end
    _unsafe_bitsetindex!(s.bits, b, diff+1, _mod64(idx))
    s
end


# An internal function to resize a Bits object and ensure the newly allocated
# elements are zeroed (will become unnecessary if this behavior changes)
@inline function _growend0!(b::Bits, nchunks::Int)
    len = length(b)
    _growend!(b, nchunks)
    for i in len+1:length(b)
        @inbounds b[i] = CHK0 # resize! gives dirty memory
    end
end

@inline function _growbeg0!(b::Bits, nchunks::Int)
    _growbeg!(b, nchunks)
    for i in 1:nchunks
        @inbounds b[i] = CHK0
    end
end

function union!(s::BitSet, r::AbstractUnitRange{<:Integer})
    isempty(r) && return s
    a, b = _check_bitset_bounds(first(r)), _check_bitset_bounds(last(r))
    cidxa = _div64(a)
    cidxb = _div64(b)
    if s.offset == NO_OFFSET
        s.offset = cidxa
    end
    len = length(s.bits)
    diffa = cidxa - s.offset
    diffb = cidxb - s.offset

    # grow s.bits as necessary
    if diffb >= len
        _growend!(s.bits, diffb - len + 1)
        # we set only some values to CHK0, those which will not be
        # fully overwritten (i.e. only or'ed with `|`)
        s.bits[end] = CHK0 # end == diffb + 1
        if diffa >= len
            s.bits[diffa + 1] = CHK0
        end
    end
    if diffa < 0
        _growbeg!(s.bits, -diffa)
        s.bits[1] = CHK0
        if diffb < 0
            s.bits[diffb - diffa + 1] = CHK0
        end
        s.offset = cidxa # s.offset += diffa
        diffb -= diffa
        diffa = 0
    end

    # update s.bits
    i = _mod64(a)
    j = _mod64(b)
    @inbounds if diffa == diffb
        s.bits[diffa + 1] |= (((~CHK0) >> i) << (i+63-j)) >> (63-j)
    else
        s.bits[diffa + 1] |= ((~CHK0) >> i) << i
        s.bits[diffb + 1] |= (~CHK0  << (63-j)) >> (63-j)
        for n = diffa+1:diffb-1
            s.bits[n+1] = ~CHK0
        end
    end
    s
end

function _matched_map!(f, s1::BitSet, s2::BitSet)
    left_false_is_false = f(false, false) == f(false, true) == false
    right_false_is_false = f(false, false) == f(true, false) == false

    # we must first handle the NO_OFFSET case; we could test for
    # isempty(s1) but it can be costly, so the user has to call
    # empty!(s1) herself before-hand to re-initialize to NO_OFFSET
    if s1.offset == NO_OFFSET
        return left_false_is_false ? s1 : copy!(s1, s2)
    elseif s2.offset == NO_OFFSET
        return right_false_is_false ? empty!(s1) : s1
    end
    s1.offset = _matched_map!(f, s1.bits, s1.offset, s2.bits, s2.offset,
                              left_false_is_false, right_false_is_false)
    s1
end

# An internal function that takes a pure function `f` and maps across two BitArrays
# allowing the lengths and offsets to be different and altering b1 with the result
# WARNING: the assumptions written in the else clauses must hold
function _matched_map!(f, a1::Bits, b1::Int, a2::Bits, b2::Int,
                       left_false_is_false::Bool, right_false_is_false::Bool)
    l1, l2 = length(a1), length(a2)
    bdiff = b2 - b1
    e1, e2 = l1+b1, l2+b2
    ediff = e2 - e1

    # map! over the common indices
    @inbounds for i = max(1, 1+bdiff):min(l1, l2+bdiff)
        a1[i] = f(a1[i], a2[i-bdiff])
    end

    if ediff > 0
        if left_false_is_false
            # We don't need to worry about the trailing bits — they're all false
        else # @assert f(false, x) == x
            _growend!(a1, ediff)
            # if a1 and a2 are not overlapping, we infer implied "false" values from a2
            for outer l1 = l1+1:bdiff
                @inbounds a1[l1] = CHK0
            end
            # update ediff in case l1 was updated
            ediff = e2 - l1 - b1
            # copy actual chunks from a2
            unsafe_copyto!(a1, l1+1, a2, l2+1-ediff, ediff)
            l1 = length(a1)
        end
    elseif ediff < 0
        if right_false_is_false
            # We don't need to worry about the trailing bits — they're all false
            _deleteend!(a1, min(l1, -ediff))
            # no need to update l1, as if bdiff > 0 (case below), then bdiff will
            # be smaller anyway than an updated l1
        else # @assert f(x, false) == x
            # We don't need to worry about the trailing bits — they already have the
            # correct value
        end
    end

    if bdiff < 0
        if left_false_is_false
            # We don't need to worry about the leading bits — they're all false
        else # @assert f(false, x) == x
            _growbeg!(a1, -bdiff)
            # if a1 and a2 are not overlapping, we infer implied "false" values from a2
            for i = l2+1:-bdiff
                @inbounds a1[i] = CHK0
            end
            b1 += bdiff # updated return value

            # copy actual chunks from a2
            unsafe_copyto!(a1, 1, a2, 1, min(-bdiff, l2))
        end
    elseif bdiff > 0
        if right_false_is_false
            # We don't need to worry about the trailing bits — they're all false
            _deletebeg!(a1, min(l1, bdiff))
            b1 += bdiff
        else # @assert f(x, false) == x
            # We don't need to worry about the trailing bits — they already have the
            # correct value
        end
    end
    b1 # the new offset
end


@noinline _throw_bitset_bounds_err() =
    throw(ArgumentError("elements of BitSet must be between typemin(Int) and typemax(Int)"))

@inline _is_convertible_Int(n) = typemin(Int) <= n <= typemax(Int)

@inline _check_bitset_bounds(n) =
    _is_convertible_Int(n) ? Int(n) : _throw_bitset_bounds_err()

@inline _check_bitset_bounds(n::Int) = n

@noinline _throw_keyerror(n) = throw(KeyError(n))

@inline push!(s::BitSet, n::Integer) = _setint!(s, _check_bitset_bounds(n), true)

push!(s::BitSet, ns::Integer...) = (for n in ns; push!(s, n); end; s)

@inline pop!(s::BitSet) = pop!(s, last(s))

@inline function pop!(s::BitSet, n::Integer)
    if n in s
        delete!(s, n)
        n
    else
        _throw_keyerror(n)
    end
end

@inline function pop!(s::BitSet, n::Integer, default)
    if n in s
        delete!(s, n)
        n
    else
        default
    end
end

@inline delete!(s::BitSet, n::Int) = _setint!(s, n, false)
@inline delete!(s::BitSet, n::Integer) = _is_convertible_Int(n) ? delete!(s, Int(n)) : s

popfirst!(s::BitSet) = pop!(s, first(s))

function empty!(s::BitSet)
    empty!(s.bits)
    s.offset = NO_OFFSET
    s
end

isempty(s::BitSet) = _check0(s.bits, 1, length(s.bits))

# Mathematical set functions: union!, intersect!, setdiff!, symdiff!

union(s::BitSet, sets...) = union!(copy(s), sets...)
union!(s1::BitSet, s2::BitSet) = _matched_map!(|, s1, s2)

intersect(s1::BitSet, s2::BitSet) =
    length(s1.bits) < length(s2.bits) ? intersect!(copy(s1), s2) : intersect!(copy(s2), s1)

intersect!(s1::BitSet, s2::BitSet) = _matched_map!(&, s1, s2)

setdiff!(s1::BitSet, s2::BitSet) = _matched_map!((p, q) -> p & ~q, s1, s2)

function symdiff!(s::BitSet, ns)
    for x in ns
        int_symdiff!(s, x)
    end
    return s
end

function int_symdiff!(s::BitSet, n::Integer)
    n0 = _check_bitset_bounds(n)
    val = !(n0 in s)
    _setint!(s, n0, val)
    s
end

symdiff!(s1::BitSet, s2::BitSet) = _matched_map!(xor, s1, s2)

filter!(f, s::BitSet) = unsafe_filter!(f, s)

@inline in(n::Int, s::BitSet) = _bits_getindex(s.bits, n, s.offset)
@inline in(n::Integer, s::BitSet) = _is_convertible_Int(n) ? in(Int(n), s) : false

function iterate(s::BitSet, (word, idx) = (CHK0, 0))
    while word == 0
        idx == length(s.bits) && return nothing
        idx += 1
        word = @inbounds s.bits[idx]
    end
    trailing_zeros(word) + (idx - 1 + s.offset) << 6, (_blsr(word), idx)
end

@noinline _throw_bitset_notempty_error() =
    throw(ArgumentError("collection must be non-empty"))

function first(s::BitSet)
    idx = _bits_findnext(s.bits, 0)
    idx == -1 ? _throw_bitset_notempty_error() : idx + intoffset(s)
end

function last(s::BitSet)
    idx = _bits_findprev(s.bits, (length(s.bits) << 6) - 1)
    idx == -1 ? _throw_bitset_notempty_error() : idx + intoffset(s)
end

length(s::BitSet) = bitcount(s.bits) # = mapreduce(count_ones, +, s.bits; init=0)

function show(io::IO, s::BitSet)
    print(io, "BitSet([")
    first = true
    for n in s
        !first && print(io, ", ")
        print(io, n)
        first = false
    end
    print(io, "])")
end

function _check0(a::Vector{UInt64}, b::Int, e::Int)
    @inbounds for i in b:e
        a[i] == CHK0 || return false
    end
    true
end

function ==(s1::BitSet, s2::BitSet)
    # Swap so s1 has always the smallest offset
    if s1.offset > s2.offset
        s1, s2 = s2, s1
    end
    a1 = s1.bits
    a2 = s2.bits
    b1, b2 = s1.offset, s2.offset
    l1, l2 = length(a1), length(a2)
    e1 = l1+b1
    overlap0 = max(0, e1 - b2)
    included = overlap0 >= l2  # whether a2's indices are included in a1's
    overlap  = included ? l2 : overlap0

    # Ensure non-overlap chunks are zero (unlikely)
    _check0(a1, 1, l1-overlap0) || return false
    if included
        _check0(a1, b2-b1+l2+1, l1) || return false
    else
        _check0(a2, 1+overlap, l2) || return false
    end

    # compare overlap values
    if overlap > 0
        t1 = @_gc_preserve_begin a1
        t2 = @_gc_preserve_begin a2
        _memcmp(pointer(a1, b2-b1+1), pointer(a2), overlap<<3) == 0 || return false
        @_gc_preserve_end t2
        @_gc_preserve_end t1
    end

    return true
end

function issubset(a::BitSet, b::BitSet)
    n = length(a.bits)
    shift = b.offset - a.offset
    i, j = shift, shift + length(b.bits)

    f(a, b) = a == a & b
    return (
        all(@inbounds iszero(a.bits[i]) for i in 1:min(n, i)) &&
        all(@inbounds f(a.bits[i], b.bits[i - shift]) for i in max(1, i+1):min(n, j)) &&
        all(@inbounds iszero(a.bits[i]) for i in max(1, j+1):n))
end
⊊(a::BitSet, b::BitSet) = a <= b && a != b


minimum(s::BitSet) = first(s)
maximum(s::BitSet) = last(s)
extrema(s::BitSet) = (first(s), last(s))
issorted(s::BitSet) = true
