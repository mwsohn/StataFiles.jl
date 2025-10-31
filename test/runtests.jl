using StataFiles, DataFrames, CategoricalArrays, FreqTables, RDatasets

mtcars = dataset("datasets", "mtcars")
rename!(mtcars, Pair.(names(mtcars), lowercase.(names(mtcars))))

mtcars.vsca = recode(mtcars.vs, (0 => "Straight", 1 => "V")...)
mtcars.vsca = categorical(mtcars.vsca, ordered=true)

@testset "Convert a DataFrame dataset to Stata .dta file" begin
    write_stata("mtcars.dta", mtcars)

    df1 = read_stata("mtcars.dta")



end


