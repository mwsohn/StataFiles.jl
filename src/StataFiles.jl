module StataFiles

using DataFrames, CategoricalArrays, TableMetadataTools, 
    OrderedCollections, Printf, Dates, InlineStrings

export read_stata, write_stata


#######################################################################
# Convert Stata DTA file to Julia DF
#######################################################################
"""
	read_stata(fn::String; chunks::Int=10, keep_original = false)

converts a stata datafile `fn` to Julia DataFrame. An original data file bigger than 100MB will be read in `chunks` (default = 10)
to save memory. Use the `keep_original = true` to save the original stata values in the imported CategoricalValues.
"""
function read_stata(fn::String; chunks::Int=10, keep_original = false)

    fh = open(fn, "r")

    # dta file (<stata_dta><header><release>)
    header = String(read(fh, 67))
    if header[2:10] != "stata_dta"
        error("Not a version 13 or 14 data file")
    end

    # data format version
    release = parse(Int16, header[29:31])
    if release == 117 # version 13
        len_varname = 33
        len_format = 49
        len_labelname = 33
        len_varlabel = 81
    elseif release == 118 # version 14
        len_varname = 129
        len_format = 57
        len_labelname = 129
        len_varlabel = 321
    else
        error("Can't convert data format version ", release, ".")
    end

    # byte order: LSF or MSF
    byteorder = header[53:55]
    if byteorder == "MSF"
        error("Big-endian data are not supported.")
    end

    # number of variables
    skip(fh, 3) # <K>
    nvar = read(fh, Int16)

    # number of observations
    skip(fh, 7) #</K><N>
    nobs = Int(read(fh, Int32))

    # dataset label length
    if release == 117
        skip(fh, 11)
        dslabel_len = read(fh, Int8)
    elseif release == 118
        skip(fh, 15)
        dslabel_len = read(fh, Int16)
    end

    # read the label
    dslabel = ""
    if dslabel_len > 0
        dslabel = String(read(fh, dslabel_len))
    end

    # time stamp
    skip(fh, 19)
    timestamplen = read(fh, Int8)
    if timestamplen > 0
        timestamp = String(read(fh, timestamplen))
    end

    # map
    skip(fh, 26) # </timestamp></header><map>
    statamap = Vector{Int64}(undef, 14)
    read!(fh, statamap)

    # variable types
    skip(fh, 22) # </map><variable_types>
    typelist = Vector{UInt16}(undef, nvar)
    read!(fh, typelist)

    # variable names
    skip(fh, 27)
    varlist = Vector{Symbol}(undef, nvar)
    for i in 1:nvar
        varlist[i] = Symbol(strtonull(String(read(fh, len_varname))))
    end

    # sort list
    skip(fh, 21) # </varnames><sortlist>
    for i in 1:nvar
        srt = read(fh, Int16)
    end

    # formats
    skip(fh, 22) # </sortlist><formats> + 2 (2 bytes left over from the previous sequence)
    fmtlist = Vector{String}(undef, nvar)
    for i in 1:nvar
        fmtlist[i] = strtonull(String(read(fh, len_format)))
    end

    # value label names
    skip(fh, 29) 
    valuelabels = Vector{String}(undef, nvar)
    numvlabels = 0
    for i in 1:nvar
        valuelabels[i] = strtonull(String(read(fh, len_labelname)))
        if length(valuelabels[i]) > 0
            numvlabels += 1
        end
    end

    # variable labels
    skip(fh, 37) # </value_label_names><variable_labels>
    varlabels = Vector{String}(undef, nvar)
    for i in 1:nvar
        varlabels[i] = strtonull(String(read(fh, len_varlabel)))
    end

    # characteristics - we will not import them
    # read until we hit '</characteristics>'
    skip(fh, 35) # </variable_labels><characteristics>
    while (true)
        readuntil(fh, '<')
        if String(copy(read(fh, 5))) == "data>"
            break
        end
    end

    # nubmer of bytes for each variable
    numbytes = get_numbytes(typelist, nvar)

    # total length of each observation
    rlen = sum(numbytes)

    # number of bytes to skip in IOBuffer
    numskip = zeros(Int, nvar)
    numskip[1] = 0
    for i in 2:length(numbytes)
        numskip[i] = numbytes[i-1] + numskip[i-1]
    end

    # save the start position of the data section
    data_pos = position(fh)

    # skip the data section for now
    skip(fh, rlen * nobs)

    # if there is strLs, read them now
    skip(fh, 7) # </data>
    tst = String(read(fh, 7))
    if tst == "<strls>"
        # read strLs
        #
        # strL. Stata 13 introduced long strings up to 2 billon characters. strLs are
        # separated by "GSO".
        # (v,o): Position in the data.frame.
        # t:     129/130 defines whether or not the strL is stored with a binary 0.
        # len:   length of the strL.
        # strl:  long string.
        strls = OrderedDict()
        t = OrderedDict()
        while (String(read(fh, 3)) == "GSO")
            v = read(fh, Int32)
            if release == 117
                o = read(fh, Int32)
            elseif release == 118
                o = read(fh, Int64)
            end
            t[(v, o)] = read(fh, UInt8)
            len = read(fh, UInt32)
            strls[(v, o)] = String(read(fh, len))
        end
    end

    tst = String(read(fh, 5))
    if tst == "trls>"
        skip(fh, 14)
    else
        error("Wrong position")
    end

    # read value labels
    value_labels = Dict()
    for i in 1:numvlabels

        skipstr = String(read(fh, 5))
        if skipstr != "<lbl>"
            break
        end
        len = read(fh, Int32)
        labname = Symbol(strtonull(String(read(fh, 129))))
        skip(fh, 3) # padding

        numvalues = read(fh,Int32)
        txtlen = read(fh, Int32)
        value_labels[labname] = Dict{Int64,String}()
        offset = Vector{Int32}(undef, numvalues)
        read!(fh, offset)
        values = Vector{Int32}(undef, numvalues)
        read!(fh, values)
        valtext = String(read(fh, txtlen))

        for k in 1:numvalues
            if k == numvalues
                offset_end = txtlen
            else
                offset_end = offset[k+1]
            end
            value_labels[labname][values[k]] = strtonull(valtext[offset[k]+1:offset_end])
        end
        skip(fh, 6) # </lbl>
    end
    
    variable_dict = Dict()
    lblname_dict = Dict()
    for i in 1:nvar
        if length(varlabels[i]) > 0
            variable_dict[i] = varlabels[i]
        end

        if length(valuelabels[i]) > 0
            lblname_dict[i] = Symbol(valuelabels[i])
        end
    end

    # read data now
    seek(fh, data_pos)

    # if the data size < 100MB, then
    # slurp the entire data section into memory
    # otherwise, we will read the data by smaller batches
    io = IOBuffer()
    if rlen * nobs < 100_000_000
        write(io, read(fh, rlen * nobs))
        seek(io, 0)
        rdf = _read_dta(io, release, rlen, nobs, nvar, varlist, typelist, fmtlist, numskip, strls)
    else
        len = max(100000, ceil(Int, nobs / chunks))
        totlen = nobs
        rdf = DataFrame()
        for nread in 1:ceil(Int, nobs / len)
            if len < totlen
                totlen -= len
            else
                len = totlen
            end
            seek(io, 0)
            write(io, read(fh, rlen * len))
            seek(io, 0)

            rdf = vcat(rdf, _read_dta(io, release, rlen, len, nvar, varlist, typelist, fmtlist, numskip, strls))
        end
    end

    # close the file
    close(fh)

    for i in 1:ncol(rdf)

        # strls will be converted to CategoricalArrays
        if typelist[i] == 32768
            rdf[!, varlist[i]] = categorical(rdf, varlist[i])
        end

        # for vectors without missing values
        if sum(ismissing.(rdf[!, varlist[i]])) == 0
            rdf[!, varlist[i]] = convert(Vector{_eltype2(rdf[!, varlist[i]])}, rdf[!, varlist[i]])
        end

        # if keep_original == false,
        # convert integer variables that have formats 
        # into CategoricalArrays with the appropriate value labels
        if keep_original == false && typelist[i] in (65528, 65529, 65530) && haskey(lblname_dict, i)
            rdf[!, varlist[i]] = categorical(recode2(rdf[!,varlist[i]], value_labels[lblname_dict[i]] ))
        end

        # variable label
        if haskey(variable_dict, i)
            TableMetadataTools.label!(rdf, varlist[i], variable_dict[i])
        end

    end

    return rdf
end

function recode2(vv::AbstractVector,dd::Dict)
    return [ haskey(dd,vv[i]) ? string(vv[i],": ",dd[    vv[i]]) : string("(",vv[i],")") for i in 1:length(vv)]
end

function _read_dta(io, release, rlen, len, nvar, varlist, typelist, fmtlist, numskip, strls)

    df = DataFrame()

    dataitemf32::Float32 = 0.0
    dataitemf64::Float64 = 0.0
    dataitemi8::Int8 = 0
    dataitemi16::Int16 = 0
    dataitemi32::Int32 = 0
    v::Int32 = 0
    o::Int64 = 0
    z = zeros(UInt8, 8)

    # interate over the number of variables
    for j in 1:nvar

        df[!, varlist[j]] = alloc_array(typelist[j], fmtlist[j], len)

        for i in 1:len
            seek(io, numskip[j] + (i - 1) * rlen)

            if 0 <= typelist[j] < 2045
                df[i, j] = strtonull(String(read(io, typelist[j])))
                # if empty string, return missing
                if df[i, j] == ""
                    df[i, j] = missing
                end
            elseif typelist[j] == 32768 # long string
                if release == 117
                    v = read(io, Int32)
                    o = read(io, Int32)
                elseif release == 118
                    z = read(io, 8)
                    v = reinterpret(Int16, z[1:2])[1]
                    o = (reinterpret(Int64, z)[1] >> 16)
                end
                if (v, o) == (0, 0)
                    df[i, j] = missing
                else
                    df[i, j] = strtonull(strls[(v, o)])
                end
            elseif typelist[j] == 65526
                dataitemf64 = read(io, Float64)
                if dataitemf64 > 8.9884656743e307
                    df[i, j] = missing
                elseif fmtlist[j] == "%d" || fmtlist[j][1:3] == "%td"
                    # convert it to Julia date
                    df[i, j] = Date(1960, 1, 1) + Dates.Day(round(Int, dataitemf64))
                elseif fmtlist[j][1:3] == "%tc" || fmtlist[j][1:3] == "%tC"
                    df[i, j] = DateTime(1960, 1, 1, 0, 0, 0) + Dates.Millisecond(round(Int, dataitemf64))
                else
                    df[i, j] = dataitemf64
                end
            elseif typelist[j] == 65527
                dataitemf32 = read(io, Float32)
                if dataitemf32 > 1.70141173319e38
                    df[i, j] = missing
                elseif fmtlist[j] == "%d" || fmtlist[j][1:3] == "%td"
                    # convert it to Julia date
                    df[i, j] = Date(1960, 1, 1) + Dates.Day(round(Int, dataitemf32))
                elseif fmtlist[j][1:3] == "%tc" || fmtlist[j][1:3] == "%tC"
                    df[i, j] = DateTime(1960, 1, 1, 0, 0, 0) + Dates.Millisecond(round(Int, dataitemf32))
                else
                    df[i, j] = dataitemf32
                end
            elseif typelist[j] == 65528
                dataitemi32 = read(io, Int32)
                if dataitemi32 > 2147483620
                    df[i, j] = missing
                elseif fmtlist[j] == "%d" || fmtlist[j][1:3] == "%td"
                    # convert it to Julia date
                    df[i, j] = Date(1960, 1, 1) + Dates.Day(dataitemi32)
                elseif fmtlist[j][1:3] == "%tc" || fmtlist[j][1:3] == "%tC"
                    df[i, j] = DateTime(1960, 1, 1) + Dates.Millisecond(dataitemi32)
                else
                    df[i, j] = dataitemi32
                end
            elseif typelist[j] == 65529
                dataitemi16 = read(io, Int16)
                if dataitemi16 > 32740
                    df[i, j] = missing
                elseif fmtlist[j] == "%d" || fmtlist[j][1:3] == "%td"
                    # convert it to Julia date
                    df[i, j] = Date(1960, 1, 1) + Dates.Day(dataitemi16)
                else
                    df[i, j] = dataitemi16
                end
            elseif typelist[j] == 65530
                dataitemi8 = read(io, Int8)
                df[i, j] = dataitemi8 > 100 ? missing : dataitemi8
            end
        end
    end

    return df
end

function _eltype2(a::AbstractArray)
    if isa(a, CategoricalArray)
        return nonmissingtype(eltype(levels(a)))
    end
    return nonmissingtype(eltype(a))
end

function get_numbytes(typelist, nvar)
    nb = Vector{UInt16}(undef, nvar)
    for i in 1:nvar
        if 0 < typelist[i] < 2045
            nb[i] = typelist[i]
        elseif typelist[i] == 32768
            nb[i] = 8
        elseif typelist[i] == 65526
            nb[i] = 8
        elseif typelist[i] == 65527
            nb[i] = 4
        elseif typelist[i] == 65528
            nb[i] = 4
        elseif typelist[i] == 65529
            nb[i] = 2
        elseif typelist[i] == 65530
            nb[i] = 1
        end
    end
    return nb
end

function strtonull(str::String)
    n = findfirst('\0', str)
    n == nothing && return str
    return str[1:n-1]
end

function alloc_array(vtype, vfmt, nobs::Int64)

    if 0 <= vtype < 2045 || vtype == 32768 # string variable
        return Vector{Union{Missing,String}}(missing, nobs)
    elseif vtype == 65526
        if vfmt == "%d" || vfmt[1:3] == "%td"
            return Vector{Union{Missing,Date}}(missing, nobs)
        elseif vfmt[1:3] == "%tc" || vfmt[1:3] == "%tC"
            return Vector{Union{Missing,DateTime}}(missing, nobs)
        else
            return Vector{Union{Missing,Float64}}(missing, nobs)
        end
    elseif vtype == 65527
        if vfmt == "%d" || vfmt[1:3] == "%td"
            return Vector{Union{Missing,Date}}(missing, nobs)
        elseif vfmt[1:3] == "%tc" || vfmt[1:3] == "%tC"
            return Vector{Union{Missing,DateTime}}(missing, nobs)
        else
            return Vector{Union{Missing,Float32}}(missing, nobs)
        end
    elseif vtype == 65528
        if vfmt == "%d" || vfmt[1:3] == "%td"
            return Vector{Union{Missing,Date}}(missing, nobs)
        elseif vfmt[1:3] == "%tc" || vfmt[1:3] == "%tC"
            return Vector{Union{Missing,DateTime}}(missing, nobs)
        else
            return Vector{Union{Missing,Int32}}(missing, nobs)
        end
    elseif vtype == 65529
        if vfmt == "%d" || vfmt[1:3] == "%td"
            return Vector{Union{Missing,Date}}(missing, nobs)
        else
            return Vector{Union{Missing,Int16}}(missing, nobs)
        end
    elseif vtype == 65530
        return Vector{Union{Missing,Int8}}(missing, nobs)
    end

    error(vtype, " is not a valid variable type in Stata.")
end


#######################################################################
# Convert Julia DF to Stata DTA format
#######################################################################

missingval = Dict(
    65529 => 32_741,
    65528 => 2_147_483_621,
    65527 => 1.702e38,
    65526 => 8.989e307
)

vtype = Dict(
    Bool => 65530,
    Int8 => 65530,
    Int16 => 65529,
    Int32 => 65528,
    Float32 => 65527,
    Float64 => 65526,
    Date => 65528,
    DateTime => 65526
)

"""
    write_stata(filename, df; maxbuffer = 10_000, verbose = true)

Converts a DataFrame into a Stata dataset. It will map the data types as follows:

DataFrame      Stata
Int8           byte
Int16          int
Int32          long
Float32        float
Foat64         double
Date           long
DateTime       double

Stata does not provide a Int64-equivalent data type. Thie program will test if 
the values of a Int64 variable are within the range of values that can be saved
as a `long`, then it will convert the data; otherwise, the variable will NOT be
converted.

Any variables of the data type that is not listed above or any variable that is
100% missing will NOT be exported either. 

All CategoricalArrays will be converted into an appropriate type and a matching
label automatically. For example, a CategoricalArray whose `levels` consist of
string values, a value label will be created and its `ref` values will be converted
as a `long` (Int32). A CategoricalArray whose `levels` are numeric values, they 
will be exported to an appropriate numeric data type.
"""
function write_stata(fn::String,outdf::AbstractDataFrame; maxbuffer = 10_000, verbose = true)

    # open the output dataset file
    if fn[end-3:end] != ".dta"
        fn = string(fn, ".dta")
    end

    outdta = open(fn,"w")

    # prepare the dataframe
    (df, datatypes, typelist, numbytes, value_labels, ca) = prepare_df(outdf,verbose=verbose)

    # cols and rows
    (rows, cols) = size(df)

    # -----------------------------------------------------
    # release 118 format parameters
    len_varname = 129
    len_format = 57
    len_labelname = 129
    len_varlabel = 321

    # header
    write(outdta,"<stata_dta><header><release>118</release><byteorder>LSF</byteorder><K>")

    # number of variables
    write(outdta,Int16(cols))
    write(outdta,"</K><N>")

    # number of observations
    write(outdta, Int64(rows))
    write(outdta, "</N><label>")

    # assume no data label
    write(outdta,UInt16(0))
    write(outdta,"</label><timestamp>")
    
    # timestamp
    ts = Dates.format(now(), "dd uuu yyyy HH:MM")
    write(outdta,UInt8(length(ts)))
    write(outdta,string(ts,"</timestamp></header>"))

    # -----------------------------------------------------
    # map
    m = zeros(Int64, 14)
    m[2] = Int64(position(outdta))
    write(outdta,"<map>")
    write(outdta,m)
    write(outdta,"</map>")

    # -----------------------------------------------------
    # variable types
    m[3] = Int64(position(outdta))
    write(outdta,"<variable_types>")
    write(outdta,UInt16.(typelist))
    write(outdta,"</variable_types>")

    # variable names
    m[4] = Int64(position(outdta))
    write(outdta,"<varnames>")
    write(outdta, get_varnames(df,len_varname))
    write(outdta,"</varnames>")

    # sortlist
    m[5] = Int64(position(outdta))
    write(outdta,"<sortlist>")
    write(outdta,zeros(Int16, cols+1))
    write(outdta,"</sortlist>")

    # formats
    m[6] = Int64(position(outdta))
    write(outdta,"<formats>")
    write(outdta,get_formats(df, typelist, len_format))
    write(outdta,"</formats>")

    # value label names
    m[7] = Int64(position(outdta))
    write(outdta,"<value_label_names>")
    write(outdta,get_label_names(df, len_labelname, ca))
    write(outdta,"</value_label_names>")

    # variable labels
    m[8] = Int64(position(outdta))
    write(outdta,"<variable_labels>")
    write(outdta,get_variable_labels(df, len_varlabel))
    write(outdta,"</variable_labels>")

    # characteristics - nothing to output
    m[9] = Int64(position(outdta))
    write(outdta,"<characteristics></characteristics>")

    # total length of a row
    rlen = sum(numbytes)
    
    # ---------------------------------------------------------
    # the rest of the map section data
    m[10] = Int64(position(outdta))
    write(outdta,"<data>")

    # --------------------------------------------------------=
    # combine rows into one iobuffer and write
    if maxbuffer < rlen
        maxbuffer = rlen
    end
    chunks = ceil(Int32, rlen * rows / maxbuffer)
    nobschunk = chunks == 1 ? nobschunk = rows : ceil(Int32, rows / (chunks - 1))
    for i = 1:chunks
        from = 1 + (i-1)*nobschunk
        to = min(from + nobschunk - 1, rows)
        write(outdta,write_chunks(df[from:to, :], datatypes, typelist, ca))
    end
    write(outdta,"</data>")

    # strL section - no strLs
    m[11] = Int64(position(outdta))
    write(outdta, "<strls></strls>")

    # value labels
    m[12] = Int64(position(outdta))
    write(outdta,"<value_labels>")
    write(outdta,value_labels)
    write(outdta,"</value_labels>")

    # at the end of stata_dta section
    m[13] =  Int64(position(outdta))

    # end of file
    write(outdta,"</stata_dta>")
    m[14] = Int64(position(outdta)) 

    # seek back to the map section and overwrite the map data
    seek(outdta, m[2]+length("<map>"))
    write(outdta, m)

    # flush iostream and close
    flush(outdta)
    close(outdta)

end

function prepare_df(outdf; verbose=verbose)

    # some types of variables cannot be ported to Stata
    # large Int64 values that cannot be saved as Int32 cannot be ported either
    notallowed = falses(size(outdf,2))
    for i in 1:ncol(outdf)
        if !in(_eltype2(outdf[:,i]), [Bool, Int8, Int16, Int32, Int64, Float32, Float64, Date, DateTime, String, String1, String3, String7, String15, String31, String63, String127, String255])
            notallowed[i] = true
        end
        if _eltype2(outdf[:,i]) == Int64
            tvec = collect(skipmissing(outdf[:,i]))
            if maximum(tvec) > 2_147_483_620 || minimum(tvec) < −2_147_483_647
                notallowed[i] = true
            end
        end
    end
    
    # report exclusions
    if verbose && sum(notallowed) > 0
        println("\n\nThese variables will NOT be exported because Stata does not allow their data types:\n")
        for (i, v) in enumerate(names(outdf))
            notallowed[i] && println(@sprintf("%-30s\t%-20s",v, _eltype2(outdf[:,v])))
        end
    end

    # subset
    df = outdf[:, findall(x -> x == false, notallowed)]

    datatypes = dtypes(df)
    ca = [ isa(x,CategoricalArray) ? true : false for x in eachcol(df)]
    (typelist, numbytes) = get_types(df)
    vlabels = get_value_labels(df)

    return df, datatypes, typelist, numbytes, vlabels, ca
end

function write_chunks(outdf, datatypes, typelist, ca)

    iobuf = IOBuffer()
    for dfrow in eachrow(outdf)
        for (i,v) in enumerate(dfrow)
            if ca[i]
                if _eltype2(outdf[:,i]) == String 
                    write(iobuf, Int32(ismissing(v) ? 2_147_483_621 : outdf[:,i].pool.invindex[v]))
                elseif datatypes[i] in (Bool, Int8)
                    write(iobuf, Int8(ismissing(v) ? 101 : unwrap(v)))
                else
                    write(iobuf, datatypes[i](ismissing(v) ? missingval[typelist[i]] : unwrap(v)))
                end
            elseif datatypes[i] in (String, String1, String3, String7, String15, String31, String63, String127, String255)
                write(iobuf, ismissing(v) ? repeat('\0', typelist[i]) : string(v, repeat('\0', typelist[i] - sizeof(v))))
            elseif datatypes[i] == Date
                write(iobuf, Int32(ismissing(v) ? 2_147_483_621 : Dates.value(v - Date(1960,1,1)))) # stata doesn't support Int64
            elseif datatypes[i] == DateTime
                write(iobuf, Float64(ismissing(v) ? 8.989e307 : Dates.value(v - DateTime(1960,1,1))))
            elseif datatypes[i] in (Bool, Int8)
                write(iobuf, Int8(ismissing(v) ? 101 : v))
            else
                write(iobuf, datatypes[i](ismissing(v) ? missingval[typelist[i]] : v))
            end
        end
    end
    return take!(iobuf)
end

function dtypes(outdf)
    t = []
    for i in 1:ncol(outdf)
        if isa(outdf[:,i], CategoricalArray)
            typ = _eltype2(outdf[:,i])
            if typ == String
                push!(t, Int32)
            else
                push!(t, typ)
            end
        elseif _eltype2(outdf[:,i]) == Int64
            push!(t, Int32)
        else
            push!(t, _eltype2(outdf[:,i]))
        end
    end
    return t
end

function getmaxbytes(s::AbstractArray)
    if isa(s, CategoricalArray) && _eltype2(s) <: CategoricalString
        return maximum(sizeof.(levels(s)))
    end

    if nmissing(s) == size(s, 1)
        return 0
    end

    return maximum(sizeof.(skipmissing(s)))
end

function nmissing(a::AbstractArray)
    return count(ismissing.(a) .== true)
end

function get_types(outdf)

    bytesize = Dict(
        65526 => 8,
        65527 => 4,
        65528 => 4,
        65529 => 2,
        65530 => 1,
    )

    tlist = zeros(Int32,ncol(outdf))
    numbytes = zeros(Int32,ncol(outdf))
    for i in 1:ncol(outdf)
        if isa(outdf[:,i], CategoricalArray)
            typ = _eltype2(outdf[:,i])
            if typ == String
                tlist[i] = 65528
                numbytes[i] = 4
            elseif typ == Bool
                tlist[i] = 65530
                numbytes[i] = 1
            else
                tlist[i] = vtype[typ]
                numbytes[i] = bytesize[tlist[i]]
            end
        else
            typ = _eltype2(outdf[:,i])
            if haskey(vtype,typ)
                tlist[i] = vtype[typ]
                numbytes[i] = bytesize[tlist[i]]
            elseif typ == Bool
                tlist[i] = 65530
                numbytes[i] = 1
            elseif typ == Int64
                tlist[i] = vtype[Int32]
                numbytes[i] = bytesize[tlist[i]]
            elseif typ in (String, String1, String3, String7, String15, String31, String63, String127, String255)
                maxlen = getmaxbytes(outdf[:,i])
                if maxlen < 2045
                    tlist[i] = maxlen + 1 # one byte for the null terminator
                    numbytes[i] = tlist[i]
                else
                    tlist[i] = 32768
                    numbytes[i] = 4
                end
            end
        end
    end

    return (tlist, numbytes)
end

function get_varnames(outdf, len)

    varstring = String[]
    for v in names(outdf)

        # first letter must be A-Z, a-z, or _
        # rest of the variable name can include A-Z, a-z, 0-9, or _
        if !startswith(v,r"[A-Za-z_]")
            v[1] = "_" # replace with an underscore
        end
        for i in 2:sizeof(v)
            if !occursin(r"[A-Za-z0-9_]",v[i:i])
                v[i] = '_'
            end
        end

        vlen = sizeof(v)

        if vlen < len - 1
            v2 = string(v,repeat('\0',len - vlen))
        else
            v2 - string(v[1:end-1],'\0')
        end
        if !in(v2,varstring)
            push!(varstring,v2)
        else
            push!(varstring,varnameunique(varstring,v2))
        end
    end
    return join(varstring,"")
end

function varnameunique(varnames, name, len)
    for i in 1:1000
        name = string(name,"_",i)
        if !in(name,varnames)
            if length(name) < len
                return name
            end
        end
    end
end

function get_formats(outdf,typelist,len)

    fvec = String[]
    for i in 1:ncol(outdf)
        if typelist[i] < 2045
            fmt = string("%-",typelist[i],"s")
            push!(fvec,string(fmt, repeat('\0',len - sizeof(fmt))))
        elseif typelist[i] == 65528 && _eltype2(outdf[:,i]) == Date
            push!(fvec,string("%tdNN-DD-CCYY",repeat('\0',len - 13)))
        elseif typelist[i] in (65528,65529,65530)
            push!(fvec,string("%8.0g",repeat('\0',len - 5)))
        elseif typelist[i] == 65527 # float
            push!(fvec,string("%6.2f",repeat('\0',len - 5)))
        elseif typelist[i] == 65526 && _eltype2(outdf[:,i]) == DateTime
            push!(fvec,string("%tc",repeat('\0',len - 3)))
        elseif typelist[i] == 65526
            push!(fvec,string("%11.1f",repeat('\0',len - 6)))
        end
    end    

    return join(fvec,"")
end

function get_label_names(outdf,len, ca)

    lvec = String[]
    for i in 1:size(outdf,2)
        if ca[i]
            lblname = string("fmt",i)
            push!(lvec,string(lblname, repeat('\0',len - sizeof(lblname))))
        else
            push!(lvec, repeat("\0",len))
        end
    end    
    return join(lvec,"")
end

function get_variable_labels(outdf, len)
    lbls = labels(outdf)
    for i in 1:length(lbls)
        lbls[i] = string(lbls[i], repeat('\0', len - sizeof(lbls[i])))
    end
    return join(lbls,"")
end

function get_value_labels(outdf)
    iobf = IOBuffer()
    for (j,v) in enumerate(propertynames(outdf))
        if isa(outdf[:,j], CategoricalArray) && _eltype2(outdf[:,v]) == String
            invindex = outdf[:,v].pool.invindex
            vindex = Dict(values(invindex) .=> keys(invindex))
            n = length(vindex)
            off = zeros(Int32,n)
            val = Int32.(sort(collect(keys(vindex))))
            txt = ""
            for (i,vv) in enumerate(val)
                off[i] = sizeof(txt)
                txt = string(txt, vindex[vv], '\0')
            end
            txtlen = sizeof(txt)
            len = 8 + 8*n + txtlen

            # write the value label to the iobuffer
            write(iobf,"<lbl>")
            write(iobf,Int32(len))
            fmt = string("fmt",j)
            write(iobf,string(fmt,repeat('\0',129 - sizeof(fmt)), "   ")) # 3 spaces padded
            write(iobf,Int32(n))
            write(iobf,Int32(txtlen))
            write(iobf,off)
            write(iobf,val)
            write(iobf,txt)
            write(iobf,"</lbl>")
        end
    end

    return take!(iobf)
end




end
