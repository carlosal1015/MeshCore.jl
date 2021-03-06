"""
    ShapeCollection{S <: AbstractShapeDesc, N, T}

This is the type of a homogeneous collection of finite element shapes.

- S = shape descriptor: subtype of AbstractShapeDesc{MD, NV, NF, FD}
- `IT` = type of the vertex numbers (some concrete type of `Integer`).
"""
struct ShapeCollection{IT, S <: AbstractShapeDesc{MD, NV, NF, FD} where {MD, NV, NF, FD}, NV}
    # Shape descriptor
    shapedesc::S
    # Connectivity: incidence relation Shape -> Vertex
    increl::IncRelFixed{NV, IT}
end

"""
    ShapeCollection(shapedesc::S, C::Array{T, 2}) where {S <: AbstractShapeDesc, T}

Convenience constructor from a matrix. One shape per row.
"""
function ShapeCollection(shapedesc::S, C::Array{IT, 2}) where {S <: AbstractShapeDesc, IT}
    cc = [SVector{nvertices(shapedesc)}(C[idx, :]) for idx in 1:size(C, 1)]
    return ShapeCollection(shapedesc, IncRelFixed(cc))
end

"""
    shapedesc(shapes::ShapeCollection)

Retrieve the shape descriptor.
"""
shapedesc(shapes::ShapeCollection) = shapes.shapedesc

"""
    connectivity(shapes::ShapeCollection, i::IT) where {IT}

Retrieve connectivity of the `i`-th shape from the collection.
"""
connectivity(shapes::ShapeCollection, i::IT) where {IT} = shapes.increl._v[i]

"""
    connectivity(shapes::ShapeCollection, I::SVector)

Retrieve connectivity of multiple shapes from the collection.

Static arrays are used to help the compiler avoid memory allocation.
"""
@generated function connectivity(shapes::ShapeCollection, I::SVector)
    nidx = length(I)
    expr = :(())
    for i in 1:nidx
        push!(expr.args, :(shapes.increl._v[I[$i]]))
    end
    return :(SVector($expr))
end

"""
    nshapes(shapes::ShapeCollection)

Number of shapes in the collection.
"""
nshapes(shapes::ShapeCollection) = nrelations(shapes.increl)

"""
    manifdim(shapes::ShapeCollection)

Retrieve the manifold dimension of the collection.
"""
manifdim(shapes::ShapeCollection) = manifdim(shapes.shapedesc)

"""
    nvertices(shapes::ShapeCollection)

Retrieve the number of vertices per shape.
"""
nvertices(shapes::ShapeCollection) = nvertices(shapes.shapedesc)

"""
    facetdesc(shapes::ShapeCollection)

Retrieve the shape type of the boundary facet.
"""
facetdesc(shapes::ShapeCollection) = shapes.shapedesc.facetdesc

"""
    nfacets(shapes::ShapeCollection)

Retrieve the number of boundary facets per shape.
"""
nfacets(shapes::ShapeCollection) = nfacets(shapes.shapedesc)

"""
    facets(shapes::ShapeCollection)

Retrieve the connectivity of the facets.
"""
facets(shapes::ShapeCollection) = shapes.shapedesc.facets

"""
    facetconnectivity(shapes::ShapeCollection, i::I, j::I) where {I}

Retrieve connectivity of the `j`-th facet shape of the `i`-th shape from the collection.
"""
function facetconnectivity(shapes::ShapeCollection, i::I, j::I) where {I}
    return shapes.increl._v[i][shapes.shapedesc.facets[j, :]]
end

"""
    edgetdesc(shapes::ShapeCollection)

Retrieve the shape type of the boundary edget.
"""
edgetdesc(shapes::ShapeCollection) = shapes.shapedesc.edgetdesc

"""
    nedgets(shapes::ShapeCollection)

Retrieve the number of boundary edgets per shape.
"""
nedgets(shapes::ShapeCollection) = nedgets(shapes.shapedesc)

"""
    edgets(shapes::ShapeCollection)

Retrieve the connectivity of the edgets.
"""
edgets(shapes::ShapeCollection) = shapes.shapedesc.edgets

"""
    edgetconnectivity(shapes::ShapeCollection, i::I, j::I) where {I}

Retrieve connectivity of the `j`-th edget shape of the `i`-th shape from the collection.
"""
function edgetconnectivity(shapes::ShapeCollection, i::I, j::I) where {I}
    return shapes.increl._v[i][shapes.shapedesc.edgets[j, :]]
end

"""
    skeleton(shapes::ShapeCollection; options...)

Compute the skeleton of the shape collection.

This computes a new shape collection from an existing shape collection. It
consists of facets (shapes of manifold dimension one less than the manifold
dimension of the shapes themselves).

# Options
- `boundaryonly`: include in the skeleton only shapes on the boundary
    of the input collection, `true` or `false` (default).
"""
function skeleton(shapes::ShapeCollection; options...)
    boundaryonly = false
    if :boundaryonly in keys(options)
        boundaryonly = options[:boundaryonly];
    end
    hfc = hyperfacecontainer()
    for i in 1:nshapes(shapes)
        for j in 1:nfacets(shapes)
            fc = facetconnectivity(shapes, i, j)
            addhyperface!(hfc, fc)
        end
    end
    c = SVector{nvertices(facetdesc(shapes)), Int64}[]
    for hfa in values(hfc)
        for hf in hfa
            if (boundaryonly && hf.nref != 2) || (!boundaryonly)
                push!(c, SVector{nvertices(facetdesc(shapes))}(hf.oc))
            end
        end
    end
    return ShapeCollection(facetdesc(shapes), IncRelFixed(c))
end

"""
    boundary(shapes::ShapeCollection)

Compute the shape collection for the boundary of the collection on input.

This is a convenience version of the `skeleton` function.
"""
function boundary(shapes::ShapeCollection)
    return skeleton(shapes; boundaryonly = true)
end

function _sense(fc, oc, nshifts) # is the facet used in the positive or in the negative sense?
	if fc == oc
		return +1 # facet used in the positive sense
	end
	for i in 1:nshifts-1
		fc = circshift(fc, 1) # try a circular shift
		if fc == oc
			return +1 # facet used in the positive sense
		end
	end
	return -1 # facet used in the positive sense
end

"""
    boundedby(shapes::ShapeCollection, facetshapes::ShapeCollection)

Compute the shape collection that expresses the incidence `d -> d-1` for `d`-dimensional shapes.

In other words, this is the incidence between shapes and the shapes that bound
these shapes (facets). For tetrahedra as the shapes, the incidence relation
lists the numbers of the faces that bound each individual tetrahedron.
The resulting shape is of the same shape description as the `shapes` on input.

!!! note
The numbers of the facets are signed: positive when the facet bounds the shape
in the sense in which it is defined by the shape as oriented with an outer
normal; negative otherwise. The sense is defined by the numbering of the
1st-order vertices of the facet shape.
"""
function boundedby(shapes::ShapeCollection, facetshapes::ShapeCollection)
	@assert manifdim(shapes) == manifdim(facetshapes)+1
	hfc = hyperfacecontainer()
    for i in 1:nshapes(facetshapes)
		fc = connectivity(facetshapes, i)
        addhyperface!(hfc, fc, i) # store the facet number with the hyper face
    end
	nsmax = nshapes(shapes)
    _v = Vector{Int64}[];
	sizehint!(_v, nsmax)
    for i in 1:nsmax
        push!(_v, fill(0, nfacets(shapes)))  # initially empty arrays
    end
	for i in 1:nshapes(shapes)
		for j in 1:nfacets(shapes)
			fc = facetconnectivity(shapes, i, j)
			hf = gethyperface(hfc, fc)
			if hf == EMPTYHYPERFACE
				@error "Hyper face not found? $(fc)"
			end
			sgn = _sense(fc[1:n1storderv(facetshapes.shapedesc)], hf.oc, nshifts(facetshapes.shapedesc))
			_v[i][j] = sgn * hf.store
		end
    end
	cc = [SVector{nfacets(shapes)}(_v[idx]) for idx in 1:length(_v)]
    return ShapeCollection(shapes.shapedesc, IncRelFixed(cc))
end

"""
    boundedby2(shapes::ShapeCollection, edgetshapes::ShapeCollection)

Compute the shape collection that expresses the incidence `d -> d-2` for `d`-dimensional shapes.

In other words, this is the incidence between shapes and the shapes that "bound"
the boundaries of these shapes (i. e. edgets). For tetrahedra as the shapes, the incidence relation
lists the numbers of the edges that "bound" each individual tetrahedron.
The resulting shape is of the same shape description as the `shapes` on input.

!!! note
The numbers of the edgets are signed: positive when the edget bounds the shape
in the sense in which it is defined by the shape as oriented with an outer
normal; negative otherwise. The sense is defined by the numbering of the
1st-order vertices of the edget shape.
"""
function boundedby2(shapes::ShapeCollection, edgetshapes::ShapeCollection)
	@assert manifdim(shapes) == manifdim(edgetshapes)+2
	hfc = hyperfacecontainer()
    for i in 1:nshapes(edgetshapes)
		fc = connectivity(edgetshapes, i)
		addhyperface!(hfc, fc, i) # store the facet number with the hyper face
    end
	nsmax = nshapes(shapes)
    _v = Vector{Int64}[];
	sizehint!(_v, nsmax)
    for i in 1:nsmax
        push!(_v, fill(0, nedgets(shapes)))  # initially empty arrays
    end
	for i in 1:nshapes(shapes)
		for j in 1:nedgets(shapes)
			fc = edgetconnectivity(shapes, i, j)
			hf = gethyperface(hfc, fc)
			if hf == EMPTYHYPERFACE
				@error "Hyper face not found? $(fc)"
			end
			sgn = _sense(fc[1:n1storderv(edgetshapes.shapedesc)], hf.oc, nshifts(edgetshapes.shapedesc))
			_v[i][j] = sgn * hf.store
		end
    end
	cc = [SVector{nedgets(shapes)}(_v[idx]) for idx in 1:length(_v)]
    return ShapeCollection(shapes.shapedesc, IncRelFixed(cc))
end
