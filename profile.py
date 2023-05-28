"""KSplit evaluation"""

# Import the Portal object.
import geni.portal as portal
# Import the ProtoGENI library.
import geni.rspec.pg as pg

# Create a portal context.
pc = portal.Context()

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

node_0 = request.RawPC('node-0')
node_0.hardware_type = 'c6420'
node_0.disk_image = 'urn:publicid:IDN+clemson.cloudlab.us+image+redshift-PG0:dramhitNix'

# Install and execute a script that is contained in the repository.
# node_0.addService(pg.Execute(shell="sh", command="/local/repository/dramhit-top.sh"))

# Print the generated rspec
pc.printRequestRSpec(request)
