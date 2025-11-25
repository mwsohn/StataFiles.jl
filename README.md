# StataFiles.jl
A Package to read and write Stata .dta files.
This may be the first Julia -> Stata conversion program. 
Despite the excellent .dta file reader in `ReadStat.jl` package,
I needed to write another .dta file reader because `ReadStat.jl`
were not able to handle very large files well that are
several gigabytes in size and all formats such as value labels
and date and datatime formats are lost during conversion.

`StataFiles.jl` provides the following functionalities:
* It is written entirely in Julia.

* When importing, it can break large files into small chunks
and can handle very large files gracefully in memory strapped situations.
Use `chunks` option to specify the number of chunks to use (default = 10).

* All variable labels will be imported using `TableMetadataTools.jl`. 

* All variables with value labels will be imported into `CategoricalArrays`. If `keep_original = false` is set,
only the value labels will be imported and the original numeric values will NOT be kept. If you want to keep
the original values, use `keep_original = true`. Then, original Stata numeric values will be prepended to the
value labels followed by a `:` (default: `false`). 

* All `int` or `long` variables with `%d` or `%td` formats will be imported as Julia dates
using the `Dates` package.

* All `float` or `double` variables with `%tc` or `%tC` formats will be
imported as Julia `DateTime` variables.

* When exporting, Julia Dates and DateTimes will be automatically converted to Stata with the formats `%tdNN-DD-CCYY` for dates
and `%tc` for datetimes.

* CategoricalArrays will be exported into `byte` or `int` types
with all value labels.

* Any variables with data types that are not supported by Stata (e.g., Int64) will NOT be exported.


## Installation

```
] add StataFiles.jl
```

## Syntax

### 1. To convert a Stata .dta file to a Julia DataFrame
```
df = read_stata(Statafilename::String; chunks::Int = 10, keep_original = false)
```

### 2. To convert a Julia DataFrame to a Stata .dta file
```
write_stata(Statafilename::String, df::AbstractDataFrame)
```


