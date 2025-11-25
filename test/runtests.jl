using Test, StataFiles, DataFrames, CategoricalArrays, FreqTables, RDatasets, Statistics, StatsBase

mtcars = dataset("datasets", "mtcars")
rename!(mtcars, Pair.(names(mtcars), lowercase.(names(mtcars))))

mtcars.vsca = recode(mtcars.vs, (0 => "Straight", 1 => "V")...)
mtcars.vsca = categorical(mtcars.vsca, ordered=true)

# @testset "Convert a DataFrame dataset to Stata .dta file" begin
    write_stata("mtcars.dta", mtcars)

    df1 = read_stata("mtcars.dta",keep_original=true)

    # number of rows and columns should match
    @test size(mtcars) == size(df1)

    # variable names should match
    @test names(mtcars) == names(df1)

    # frequency of mtcars.model and df1.model should match (they are in different types!)
    @test freqtable(mtcars.model) == freqtable(df1.model)

    # all columns must also match
    @test mean_and_std(mtcars[!, :mpg]) == mean_and_std(df1[!, :mpg])
    @test mean_and_std(mtcars[!, :cyl]) == mean_and_std(df1[!, :cyl])
    @test mean_and_std(mtcars[!, :disp]) == mean_and_std(df1[!, :disp])
    @test mean_and_std(mtcars[!, :hp]) == mean_and_std(df1[!, :hp])
    @test mean_and_std(mtcars[!, :drat]) == mean_and_std(df1[!, :drat])
    @test mean_and_std(mtcars[!, :wt]) == mean_and_std(df1[!, :wt])
    @test mean_and_std(mtcars[!, :qsec]) == mean_and_std(df1[!, :qsec])
@test mean_and_std(mtcars[!, :vs]) == mean_and_std(df1[!, :vs])
@test mean_and_std(mtcars[!, :am]) == mean_and_std(df1[!, :am])
@test mean_and_std(mtcars[!, :gear]) == mean_and_std(df1[!, :gear])
@test mean_and_std(mtcars[!, :carb]) == mean_and_std(df1[!, :carb])
@test mean_and_std(mtcars[!, :drat]) == mean_and_std(df1[!, :drat])
tab(mtcars,:vsca)
freqtable(df1,:vsca)



# end
using Stella
descr(mtcars)
descr(df1)

