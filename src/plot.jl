
type CurrentPlot
    nullableplot::Nullable{AbstractPlot}
end
const CURRENT_PLOT = CurrentPlot(Nullable{AbstractPlot}())

isplotnull() = isnull(CURRENT_PLOT.nullableplot)

function current()
    if isplotnull()
        error("No current plot/subplot")
    end
    get(CURRENT_PLOT.nullableplot)
end
current(plot::AbstractPlot) = (CURRENT_PLOT.nullableplot = Nullable(plot))

# ---------------------------------------------------------


Base.string(plt::Plot) = "Plot{$(plt.backend) n=$(plt.n)}"
Base.print(io::IO, plt::Plot) = print(io, string(plt))
Base.show(io::IO, plt::Plot) = print(io, string(plt))

getplot(plt::Plot) = plt
getplotargs(plt::Plot, idx::Int = 1) = plt.plotargs
convertSeriesIndex(plt::Plot, n::Int) = n

# ---------------------------------------------------------


"""
The main plot command.  Use `plot` to create a new plot object, and `plot!` to add to an existing one:

```
    plot(args...; kw...)                  # creates a new plot window, and sets it to be the current
    plot!(args...; kw...)                 # adds to the `current`
    plot!(plotobj, args...; kw...)        # adds to the plot `plotobj`
```

There are lots of ways to pass in data, and lots of keyword arguments... just try it and it will likely work as expected.
When you pass in matrices, it splits by columns.  See the documentation for more info.
"""

# this creates a new plot with args/kw and sets it to be the current plot
function plot(args...; kw...)
    pkg = backend()
    d = KW(kw)
    preprocessArgs!(d)
    dumpdict(d, "After plot preprocessing")

    plotargs = merge(d, getPlotArgs(pkg, d, 1))
    dumpdict(plotargs, "Plot args")
    plt = _create_plot(pkg, plotargs)  # create a new, blank plot

    delete!(d, :background_color)
    plot!(plt, args...; kw...)  # add to it
end



# this adds to the current plot, or creates a new plot if none are current
function  plot!(args...; kw...)
    local plt
    try
        plt = current()
    catch
        return plot(args...; kw...)
    end
    plot!(current(), args...; kw...)
end

# this adds to a specific plot... most plot commands will flow through here
function plot!(plt::Plot, args...; kw...)
    d = KW(kw)
    userkw = preprocessArgs!(d)

    # for plotting recipes, swap out the args and update the parameter dictionary
    args = RecipesBase.apply_recipe(d, userkw, args...)
    _add_markershape(d)

    dumpdict(d, "After plot! preprocessing")
    warnOnUnsupportedArgs(plt.backend, d)

    # just in case the backend needs to set up the plot (make it current or something)
    _before_add_series(plt)

    # # grouping
    groupby = if haskey(d, :group)
        extractGroupArgs(d[:group], args...)
    else
        nothing
    end

    # merge plot args
    if !haskey(d, :subplot)
        for k in keys(_plotDefaults)
            if haskey(d, k)
                plt.plotargs[k] = d[k]
            end
        end
        # merge!(plt.plotargs, d)
        handlePlotColors(plt.backend, plt.plotargs)
    end

    _add_series(plt, d, groupby, args...)
    _add_annotations(plt, d)

    warnOnUnsupportedScales(plt.backend, d)


    # add title, axis labels, ticks, etc
    if !haskey(d, :subplot)
        merge!(plt.plotargs, d)
        # handlePlotColors(plt.backend, plt.plotargs)
        dumpdict(plt.plotargs, "Updating plot items")
        _update_plot(plt, plt.plotargs)
    end

    _update_plot_pos_size(plt, d)

    current(plt)

    # note: lets ignore the show param and effectively use the semicolon at the end of the REPL statement
    # # do we want to show it?
    if haskey(d, :show) && d[:show]
        gui()
    end

    plt
end

# handle the grouping
function _add_series(plt::Plot, d::KW, groupby::GroupBy, args...)
    starting_n = plt.n
    for (i, glab) in enumerate(groupby.groupLabels)
        tmpd = copy(d)
        tmpd[:numUncounted] = plt.n - starting_n
        _add_series(plt, tmpd, nothing, args...;
                    idxfilter = groupby.groupIds[i],
                    grouplabel = string(glab))
    end
end

filter_data(v::AVec, idxfilter::AVec{Int}) = v[idxfilter]
filter_data(v, idxfilter) = v

function filter_data!(d::KW, idxfilter)
    for s in (:x, :y, :z)
        d[s] = filter_data(get(d, s, nothing), idxfilter)
    end
end

function _replace_linewidth(d::KW)
    # get a good default linewidth... 0 for surface and heatmaps
    if get(d, :linewidth, :auto) == :auto
        d[:linewidth] = (get(d, :linetype, :path) in (:surface,:heatmap,:image) ? 0 : 1)
    end
end

# no grouping
function _add_series(plt::Plot, d::KW, ::Void, args...;
                     idxfilter = nothing,
                     grouplabel = "")

    # get the list of dictionaries, one per series
    dumpdict(d, "before process_inputs")
    process_inputs(plt, d, args...)
    dumpdict(d, "after process_inputs")

    if idxfilter != nothing
        # add the group name as the label if there isn't one passed in
        get!(d, :label, grouplabel)
        # filter the data
        filter_data!(d, idxfilter)
    end
    # dumpdict(d,"",true)

    seriesArgList, xmeta, ymeta = build_series_args(plt, d) #, idxfilter)
    # seriesArgList, xmeta, ymeta = build_series_args(plt, groupargs..., args...; d...)

    # if we were able to extract guide information from the series inputs, then update the plot
    # @show xmeta, ymeta
    updateDictWithMeta(d, plt.plotargs, xmeta, true)
    updateDictWithMeta(d, plt.plotargs, ymeta, false)

    # now we can plot the series
    for (i,di) in enumerate(seriesArgList)
        plt.n += 1

        if !stringsSupported() && di[:linetype] != :pie
            setTicksFromStringVector(plt, d, di, "x")
            setTicksFromStringVector(plt, d, di, "y")
            setTicksFromStringVector(plt, d, di, "z")
        end

        # remove plot args
        for k in keys(_plotDefaults)
            delete!(di, k)
        end

        # merge in plotarg_overrides
        plotarg_overrides = pop!(di, :plotarg_overrides, nothing)
        if plotarg_overrides != nothing
            merge!(plt.plotargs, plotarg_overrides)
        end
        # dumpdict(plt.plotargs, "pargs", true)

        dumpdict(di, "Series $i")

        _replace_linewidth(di)

        _add_series(plt.backend, plt, di)
    end
end

# --------------------------------------------------------------------

function get_indices(orig, labels)
    Int[findnext(labels, l, 1) for l in orig]
end

function setTicksFromStringVector(plt::Plot, d::KW, di::KW, letter)
    sym = symbol(letter)
    ticksym = symbol(letter * "ticks")
    pargs = plt.plotargs
    v = di[sym]

    # do we really want to do this?
    typeof(v) <: AbstractArray || return
    isempty(v) && return
    trueOrAllTrue(_ -> typeof(_) <: AbstractString, v) || return

    # compute the ticks and labels
    ticks, labels = if ticksType(pargs[ticksym]) == :ticks_and_labels
        # extend the existing ticks and labels. only add to labels if they're new!
        ticks, labels = pargs[ticksym]
        newlabels = filter(_ -> !(_ in labels), unique(v))
        newticks = if isempty(ticks)
            collect(1:length(newlabels))
        else
            maximum(ticks) + collect(1:length(newlabels))
        end
        ticks = vcat(ticks, newticks)
        labels = vcat(labels, newlabels)
        ticks, labels
    else
        # create new ticks and labels
        newlabels = unique(v)
        collect(1:length(newlabels)), newlabels
    end

    d[ticksym] = ticks, labels
    plt.plotargs[ticksym] = ticks, labels

    # add an origsym field so that later on we can re-compute the x vector if ticks change
    origsym = symbol(letter * "orig")
    di[origsym] = v
    di[sym] = get_indices(v, labels)

    # loop through existing plt.seriesargs and adjust indices if there is an origsym key
    for sargs in plt.seriesargs
        if haskey(sargs, origsym)
            # TODO: might need to call the setindex function instead to trigger a plot update for some backends??
            sargs[sym] = get_indices(sargs[origsym], labels)
        end
    end
end

# --------------------------------------------------------------------

_before_add_series(plt::Plot) = nothing

# --------------------------------------------------------------------

# should we update the x/y label given the meta info during input slicing?
function updateDictWithMeta(d::KW, plotargs::KW, meta::Symbol, isx::Bool)
    lsym = isx ? :xlabel : :ylabel
    if plotargs[lsym] == default(lsym)
        d[lsym] = string(meta)
    end
end
updateDictWithMeta(d::KW, plotargs::KW, meta, isx::Bool) = nothing

# --------------------------------------------------------------------

annotations(::@compat(Void)) = []
annotations{X,Y,V}(v::AVec{@compat(Tuple{X,Y,V})}) = v
annotations{X,Y,V}(t::@compat(Tuple{X,Y,V})) = [t]
annotations(v::AVec{PlotText}) = v
annotations(v::AVec) = map(PlotText, v)
annotations(anns) = error("Expecting a tuple (or vector of tuples) for annotations: ",
                       "(x, y, annotation)\n    got: $(typeof(anns))")

function _add_annotations(plt::Plot, d::KW)
    anns = annotations(get(d, :annotation, nothing))
    if !isempty(anns)

        # if we just have a list of PlotText objects, then create (x,y,text) tuples
        if typeof(anns) <: AVec{PlotText}
            x, y = plt[plt.n]
            anns = Tuple{Float64,Float64,PlotText}[(x[i], y[i], t) for (i,t) in enumerate(anns)]
        end

        _add_annotations(plt, anns)
    end
end


# --------------------------------------------------------------------

function Base.copy(plt::Plot)
    backend(plt.backend)
    plt2 = plot(; plt.plotargs...)
    for sargs in plt.seriesargs
        sargs = filter((k,v) -> haskey(_seriesDefaults,k), sargs)
        plot!(plt2; sargs...)
    end
    plt2
end

# --------------------------------------------------------------------
