<%!
    from sailfish import sym
    import sympy
%>

<%def name="bgk_args_decl_sc()">
	float rho, float phi, float *iv0, float *ea0, float *ea1
</%def>

<%def name="bgk_args_decl_fe()">
	float rho, float phi, float lap1, float *iv0, float *grad1
</%def>

<%def name="bgk_args_sc()">
	g0m0, g1m0, v, sca0, sca1
</%def>

<%def name="bgk_args_fe()">
	g0m0, g1m0, lap1, v, grad1
</%def>

// In the free-energy model, the relaxation time is a local quantity.
%if simtype == 'shan-chen':
	${const_var} float tau0 = ${tau}f;		// relaxation time
%endif
${const_var} float tau1 = ${tau_phi}f;		// relaxation time for the order parameter
${const_var} float visc = ${visc}f;		// viscosity

<%namespace file="opencl_compat.mako" import="*" name="opencl_compat"/>
<%namespace file="kernel_common.mako" import="*" name="kernel_common"/>
${kernel_common.nonlocal_fields_decl()}
%if simtype == 'shan-chen':
	${kernel_common.body(bgk_args_decl_sc)}
%elif simtype == 'free-energy':
	${kernel_common.body(bgk_args_decl_fe)}
%endif
<%namespace file="code_common.mako" import="*"/>
<%namespace file="boundary.mako" import="*" name="boundary"/>
<%namespace file="relaxation.mako" import="*" name="relaxation"/>
<%namespace file="propagation.mako" import="*"/>

<%include file="finite_difference_optimized.mako"/>

<%def name="init_dist_with_eq()">
	%if simtype == 'free-energy':
		float lap1, grad1[${dim}];
		%if dim == 2:
			laplacian_and_grad(iphi, -1, gi, &lap1, grad1, gx, gy);
		%else:
			laplacian_and_grad(iphi, -1, gi, &lap1, grad1, gx, gy, gz);
		%endif
	%endif

	%for local_var in bgk_equilibrium_vars:
		float ${cex(local_var.lhs)} = ${cex(local_var.rhs, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[0]):
		${get_odist('dist1_in', i)} = ${cex(feq, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[1]):
		${get_odist('dist2_in', i)} = ${cex(feq, vectors=True)};
	%endfor
</%def>

%if dim == 2:
${kernel} void SetLocalVelocity(
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${global_ptr} float *irho,
	${global_ptr} float *iphi,
	${kernel_args_1st_moment('ov')}
	int x, int y, float vx, float vy)
{
	int gx = x + get_global_id(0) - get_local_size(1) / 2;
	int gy = y + get_global_id(1) - get_local_size(1) / 2;

	${wrap_coords()}

	int gi = gx + ${arr_nx}*gy;
	float rho = irho[gi];
	float phi = iphi[gi];
	float v0[${dim}];

	v0[0] = vx;
	v0[1] = vy;

	${init_dist_with_eq()}

	ovx[gi] = vx;
	ovy[gi] = vy;
}
%endif

// A kernel to set the node distributions using the equilibrium distributions
// and the macroscopic fields.
${kernel} void SetInitialConditions(
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${kernel_args_1st_moment('iv')}
	${global_ptr} float *irho,
	${global_ptr} float *iphi)
{
	${local_indices()}

	// Cache macroscopic fields in local variables.
	float rho = irho[gi];
	float phi = iphi[gi];
	float v0[${dim}];

	v0[0] = ivx[gi];
	v0[1] = ivy[gi];
	%if dim == 3:
		v0[2] = ivz[gi];
	%endif

	${init_dist_with_eq()}
}

${kernel} void PrepareMacroFields(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${global_ptr} float *orho,
	${global_ptr} float *ophi)
{
	${local_indices()}

	int ncode = map[gi];
	int type = decodeNodeType(ncode);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	int orientation = decodeNodeOrientation(ncode);

	%if simtype == 'shan-chen' and not bc_wall_.wet_nodes:
		// Do not update the macroscopic fields for wall nodes which do not
		// represent any fluid.
		if (isWallNode(type))
			return;
	%endif

	%if bc_pressure == 'guo':
		// Do not not update the fields for pressure nodes, where by definition
		// they are constant.
		if (isPressureNode(type))
			return;
	%endif

	Dist fi;
	float out;
	getDist(&fi, dist1_in, gi);
	get0thMoment(&fi, type, orientation, &out);
	orho[gi] = out;

	int helper_idx = gi;

	%if simtype == 'free-energy':
		// Assume neutral wetting for all walls by setting adjusting the phase gradient
		// near the wall.
		//
		// This wetting boundary condition implementation is as in option 2 in
		// Halim Kusumaatmaja's PhD thesis, p.18.
		if (isWallNode(type)) {
			switch (orientation) {
				%for dir in grid.dir2vecidx.keys():
					## Symbols used on the schematics below:
					##
					## W: wall node (current node, pointed to by 'gi')
					## F: fluid node
					## |: actual location of the wall
					## .: space between fluid nodes
					## x: node from which data is read
					## y: node to which data is being written
					##
					## The schematics assume a bc_wall_grad_order of 2.
					case ${dir}: {
						## Full BB: F . F | W
						##          x ----> y
						%if bc_wall == 'fullbb':
							%if dim == 3:
								helper_idx += ${rel_offset(*(bc_wall_grad_order*grid.dir_to_vec(dir)))};
							%else:
								## rel_offset() needs a 3-vector, so make the z-coordinate 0
								helper_idx += ${rel_offset(*(list(bc_wall_grad_order*grid.dir_to_vec(dir)) + [0]))};
							%endif
						## Full BB: F . W | U
						##          x ----> y
						%elif bc_wall == 'halfbb' and bc_wall_grad_order == 1:
							%if dim == 3:
								helper_idx -= ${rel_offset(*(grid.dir_to_vec(dir)))};
							%else:
								helper_idx -= ${rel_offset(*(list(grid.dir_to_vec(dir)) + [0]))};
							%endif
						%else:
							WETTING_BOUNDARY_CONDITIONS_UNSUPPORTED_FOR_${bc_wall}_AND_GRAD_ORDER_${bc_wall_grad_order}
						%endif
						break;
					}
				%endfor
			}
		}
	%endif

	%if bc_wall == 'fullbb':
		getDist(&fi, dist2_in, helper_idx);
		get0thMoment(&fi, type, orientation, &out);
		%if simtype == 'free-energy':
			if (helper_idx != gi) {
				ophi[gi] = out - (${bc_wall_grad_order*bc_wall_grad_phase});
			} else
		%endif
		{
			ophi[gi] = out;
		}
	%elif bc_wall == 'halfbb':
		getDist(&fi, dist2_in, gi);
		get0thMoment(&fi, type, orientation, &out);
		ophi[gi] = out;
		%if simtype == 'free-energy':
			if (helper_idx != gi) {
				ophi[helper_idx] = out - (${bc_wall_grad_order*bc_wall_grad_phase});
			}
		%endif
	%endif
}

${kernel} void CollideAndPropagate(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist1_out,
	${global_ptr} float *dist2_in,
	${global_ptr} float *dist2_out,
	${global_ptr} float *gg0m0,
	${global_ptr} float *gg1m0,
	${kernel_args_1st_moment('ov')}
	int save_macro)
{
	${local_indices()}

	// shared variables for in-block propagation
	%for i in sym.get_prop_dists(grid, 1):
		${shared_var} float prop_${grid.idx_name[i]}[BLOCK_SIZE];
	%endfor
	%for i in sym.get_prop_dists(grid, 1):
		#define prop_${grid.idx_name[grid.idx_opposite[i]]} prop_${grid.idx_name[i]}
	%endfor

	int ncode = map[gi];
	int type = decodeNodeType(ncode);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	int orientation = decodeNodeOrientation(ncode);

	%if bc_pressure == 'guo':
		int orig_gi = gi;
		if (isPressureNode(type)) {
			switch (orientation) {
				%for dir_ in grid.dir2vecidx.keys():
					case (${dir_}): {
						## TODO: add a function to calculate the local indices from gi
						%if dim == 2:
							gi += ${rel_offset(*(list(grid.dir_to_vec(dir_)) + [0]))};
							gx += ${grid.dir_to_vec(dir_)[0]};
							gy += ${grid.dir_to_vec(dir_)[1]};
						%else:
							gi += ${rel_offset(*(grid.dir_to_vec(dir_)))};
							gx += ${grid.dir_to_vec(dir_)[0]};
							gy += ${grid.dir_to_vec(dir_)[1]};
							gz += ${grid.dir_to_vec(dir_)[2]};
						%endif
						break;
					}
				%endfor
			}
		}
	%endif

	%if simtype == 'free-energy':
		float lap1, grad1[${dim}];

		if (isWetNode(type)) {
			%if dim == 2:
				laplacian_and_grad(gg1m0, 1, gi, &lap1, grad1, gx, gy);
			%else:
				laplacian_and_grad(gg1m0, 1, gi, &lap1, grad1, gx, gy, gz);
			%endif
		}
	%elif simtype == 'shan-chen':
		${sc_calculate_accel()}
	%endif

	// cache the distributions in local variables
	Dist d0, d1;
	getDist(&d0, dist1_in, gi);
	getDist(&d1, dist2_in, gi);

	%if bc_pressure == 'guo':
		if (isPressureNode(type)) {
			gi = orig_gi;
		}
	%endif

	// macroscopic quantities for the current cell
	float g0m0, v[${dim}], g1m0;

	%if simtype == 'free-energy':
		getMacro(&d0, ncode, type, orientation, &g0m0, v);
		get0thMoment(&d1, type, orientation, &g1m0);
	%elif simtype == 'shan-chen':
		${sc_macro_fields()}
	%endif

	precollisionBoundaryConditions(&d0, ncode, type, orientation, &g0m0, v);
	precollisionBoundaryConditions(&d1, ncode, type, orientation, &g1m0, v);

	%if simtype == 'shan-chen':
		${relaxate(bgk_args_sc)}
	%elif simtype == 'free-energy':
		${relaxate(bgk_args_fe)}
	%endif

	// FIXME: In order for the half-way bounce back boundary condition to work, a layer of unused
	// nodes currently has to be placed behind the wall layer.
	postcollisionBoundaryConditions(&d0, ncode, type, orientation, &g0m0, v, gi, dist1_out);
	postcollisionBoundaryConditions(&d1, ncode, type, orientation, &g1m0, v, gi, dist2_out);

	%if bc_pressure == 'guo':
		if (isPressureNode(type)) {
			switch (orientation) {
				%for dir_ in grid.dir2vecidx.keys():
					case (${dir_}): {
						## TODO: add a function to calculate the local indices from gi
						gx -= ${grid.dir_to_vec(dir_)[0]};
						gy -= ${grid.dir_to_vec(dir_)[1]};
						%if dim == 3:
							gz -= ${grid.dir_to_vec(dir_)[2]};
						%endif
						break;
					}
				%endfor
			}
		}
	%endif

	// only save the macroscopic quantities if requested to do so
	if (save_macro == 1) {
		%if simtype == 'shan-chen' and not bc_wall_.wet_nodes:
			if (!isWallNode(type))
		%endif
		{
			ovx[gi] = v[0];
			ovy[gi] = v[1];
			%if dim == 3:
				ovz[gi] = v[2];
			%endif
		}
	}

	${propagate('dist1_out', 'd0')}
	${barrier()}
	${propagate('dist2_out', 'd1')}
}


