# Copyright (c) 2019, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

cimport cugraph.centrality.katz_centrality as c_katz
from cugraph.structure.graph cimport *
from cugraph.structure import graph_wrapper
from cugraph.utilities.column_utils cimport *
from cugraph.utilities.unrenumber import unrenumber
from libcpp cimport bool
from libc.stdint cimport uintptr_t
from libc.stdlib cimport calloc, malloc, free
from libc.float cimport FLT_MAX_EXP

import cudf
import cudf._lib as libcudf
import rmm
import numpy as np


def katz_centrality(input_graph, alpha=0.1, max_iter=100, tol=1.0e-5, nstart=None, normalized=True):
    """
    Call katz_centrality
    """
    cdef uintptr_t graph = graph_wrapper.allocate_cpp_graph()
    cdef Graph * g = <Graph*> graph

    if input_graph.adjlist:
        [offsets, indices] = graph_wrapper.datatype_cast([input_graph.adjlist.offsets, input_graph.adjlist.indices], [np.int32])
        [weights] = graph_wrapper.datatype_cast([input_graph.adjlist.weights], [np.float32, np.float64])
        graph_wrapper.add_adj_list(graph, offsets, indices, weights)
    else:
        [src, dst] = graph_wrapper.datatype_cast([input_graph.edgelist.edgelist_df['src'], input_graph.edgelist.edgelist_df['dst']], [np.int32])
        if input_graph.edgelist.weights:
            [weights] = graph_wrapper.datatype_cast([input_graph.edgelist.edgelist_df['weights']], [np.float32, np.float64])
            graph_wrapper.add_edge_list(graph, src, dst, weights)
        else:
            graph_wrapper.add_edge_list(graph, src, dst)
        add_adj_list(g)
        offsets, indices, values = graph_wrapper.get_adj_list(graph)
        input_graph.adjlist = input_graph.AdjList(offsets, indices, values)

    # we should add get_number_of_vertices() to Graph (and this should be
    # used instead of g.adjList.offsets.size - 1)
    num_verts = g.adjList.offsets.size - 1

    df = cudf.DataFrame()
    df['vertex'] = cudf.Series(np.zeros(num_verts, dtype=np.int32))
    cdef gdf_column c_identifier_col = get_gdf_column_view(df['vertex'])
    df['katz_centrality'] = cudf.Series(np.zeros(num_verts, dtype=np.float64))

    cdef bool has_guess = <bool> 0
    if nstart is not None:
        if len(nstart) != num_verts:
            raise ValueError('nstart must have initial guess for all vertices')

        if input_graph.renumbered is True:
            renumber_series = cudf.Series(input_graph.edgelist.renumber_map.index,
                                          index=input_graph.edgelist.renumber_map)
            nstart_vertex_renumbered = cudf.Series(renumber_series.loc[nstart['vertex']], dtype=np.int32)
            df['katz_centrality'] = cudf.Series(cudf._lib.copying.scatter(nstart['values']._column,
                                                nstart_vertex_renumbered._column,
                                                df['katz_centrality']._column))
        else:
            df['katz_centrality'] = cudf.Series(cudf._lib.copying.scatter(nstart['values']._column,
                                                nstart['vertex']._column,
                                                df['katz_centrality']._column))
        has_guess = <bool> 1

    g.adjList.get_vertex_identifiers(&c_identifier_col)
    cdef gdf_column c_katz_centrality_col = get_gdf_column_view(df['katz_centrality'])
    c_katz.katz_centrality(g, &c_katz_centrality_col, alpha, max_iter, tol, has_guess, normalized)

    if input_graph.renumbered:
        df = unrenumber(input_graph.edgelist.renumber_map, df, 'vertex')

    return df
