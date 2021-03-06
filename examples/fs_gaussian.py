#!/usr/bin/python

import numpy
from sailfish import geo, lbm

class LBMGeoFS(geo.LBMGeo2D):
    ic_fields = False

    def init_dist(self, dist):
        sigma = min(self.lat_ny, self.lat_nx) / 12.0
        amp = 0.4

        vx = vy = numpy.zeros_like(dist[0]).astype(numpy.float32)
        hx, hy = numpy.mgrid[
                (-self.lat_ny/2.0):(self.lat_ny/2.0):complex(0, self.lat_ny),
                (-self.lat_nx/2.0):(self.lat_nx/2.0):complex(0, self.lat_nx)].astype(numpy.float32)

        h = 1.0 + amp * numpy.exp(-(numpy.square(hx) + numpy.square(hy)) / sigma**2)
        self.velocity_to_dist(slice(None), (vx, vy), dist, h)

class FSSim(lbm.FreeSurfaceLBMSim):
    filename = 'fs_exp'

    def __init__(self, geo_class):
        lbm.FreeSurfaceLBMSim.__init__(self, geo_class, defaults={'verbose':
            True, 'every': 10, 'visc': 0.005})

sim = FSSim(LBMGeoFS)
sim.run()
