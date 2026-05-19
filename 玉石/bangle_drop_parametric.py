# -*- coding: utf-8 -*-
# Abaqus/CAE noGUI script
# File: bangle_drop_parametric.py
#
# Purpose:
#   Parametric Abaqus/Explicit drop-impact model for a jade bangle.
#   Geometry is generated directly as a torus:
#       inner diameter = 55 mm
#       circular tube diameter = 10 mm
#
# Important placement rule:
#   The bangle is rotated first, then translated by a closed-form geometric formula.
#   This avoids initial overclosure/contact penetration with the ground.
#
# Run in Abaqus:
#   abaqus cae noGUI=bangle_drop_parametric.py

from abaqus import *
from abaqusConstants import *
from caeModules import *
import regionToolset
import mesh
import math
import os
import time
import datetime


# ============================================================
# 0. USER PARAMETERS
# ============================================================

# ---------- Working directory ----------
WORK_DIR = r"D:\A_homework\Stone_simulation\RESULTS"
CAE_NAME = "Bangle_Drop_AI_full25_autoV.cae"

# ---------- Case mode ----------
# "test"   : only build one case for debugging
# "test4"  : build and optionally submit 4 jobs for checking batch running
# "full25" : build 5 heights x 5 angles = 25 cases
CASE_MODE = "full25"

# Submit jobs automatically?
# Recommended: False first. After checking the model, change to True.
SUBMIT_JOBS = False

# ---------- Unit system ----------
# length: mm, force: N, time: s, stress: MPa, density: tonne/mm^3
G_MM = 9800.0      # gravitational acceleration, mm/s^2

# ---------- Bangle geometry ----------
INNER_DIAMETER = 55.0     # mm, inner hole diameter
TUBE_DIAMETER = 10.0      # mm, circular cross-section diameter
TUBE_RADIUS = TUBE_DIAMETER / 2.0
MAJOR_RADIUS = INNER_DIAMETER / 2.0 + TUBE_RADIUS
OUTER_DIAMETER = INNER_DIAMETER + 2.0 * TUBE_DIAMETER

# ---------- Ground and initial clearance ----------
GROUND_SIZE = 200.0       # mm
INITIAL_GAP = 0.10        # mm, positive gap between lowest point and ground

# ---------- Material parameters ----------
E_JADE = 60000.0          # MPa
NU_JADE = 0.25
RHO_JADE = 2.8e-9         # tonne/mm^3, about 2800 kg/m^3

# ---------- Explicit step ----------
STEP_TIME = 0.006         # s
NUM_INTERVALS = 150
USE_GRAVITY = True        # add gravity field in Step-1, comp3 = -9800 mm/s^2

# Initial speed is computed automatically from each assumed drop height H:
#     v0 = sqrt(2 * G_MM * h_mm)
# and applied as velocity3 = -v0.
# Therefore H0p2, H0p4, ..., H1 will use different initial velocities.
USE_HEIGHT_BASED_INITIAL_VELOCITY = True

# ---------- Mesh ----------
BANGLE_MESH_SIZE = 1.50   # mm
GROUND_MESH_SIZE = 5.0    # mm

# Bangle element option:
#   "TET10M" is more robust for a torus geometry.
#   If too slow, try "TET4".
BANGLE_ELEMENT = "TET10M"

# ---------- Contact ----------
DEFAULT_MU = 0.10

# ---------- Job ----------
# Each Abaqus job uses 3 CPU domains. If the workstation has about 12 cores,
# MAX_PARALLEL_JOBS = 4 means four jobs can run at the same time.
NUM_CPUS = 3
NUM_DOMAINS = 3
MAX_PARALLEL_JOBS = 4
WAIT_FOR_BATCH_COMPLETION = True

# Time suffix to avoid duplicate Abaqus job/model names.
RUN_TAG = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")


# ============================================================
# 1. CASE DEFINITIONS
# ============================================================

def format_number_tag(value):
    """
    Convert a number to an Abaqus-safe short tag.
    Examples:
        1.0  -> "1"
        0.5  -> "0p5"
        45.0 -> "45"
    """
    value = float(value)
    if abs(value - round(value)) < 1.0e-8:
        return str(int(round(value)))
    text = ("%.3f" % value).rstrip("0").rstrip(".")
    return text.replace("-", "m").replace(".", "p")


def make_case_id(h_m, theta_deg, mu):
    """
    Parameter-based job name.
    Example:
        h_m = 1.0, theta_deg = 10 -> H1A10_20260517_203000

    The friction coefficient is omitted from the name because this script uses
    mu = 0.1 by default. If different mu values are used later, the name can be
    changed to include MU%s.
    """
    h_tag = format_number_tag(h_m)
    a_tag = format_number_tag(theta_deg)
    return "H%sA%s_%s" % (h_tag, a_tag, RUN_TAG)


def make_case(h_m, theta_deg, mu=DEFAULT_MU, mesh_size=BANGLE_MESH_SIZE):
    return {
        "case_id": make_case_id(h_m, theta_deg, mu),
        "h_m": h_m,
        "theta_deg": theta_deg,
        "mu": mu,
        "mesh_size": mesh_size,
    }


def make_full25_cases():
    heights = [0.2, 0.4, 0.6, 0.8, 1.0]       # m
    angles = [0.0, 30.0, 45.0, 60.0, 90.0]     # degree
    cases = []
    for h in heights:
        for theta in angles:
            cases.append(make_case(h, theta, DEFAULT_MU, BANGLE_MESH_SIZE))
    return cases


def make_test4_cases():
    """
    Four jobs for checking batch generation/submission.
    The second case is named like H1A10_time, matching the requested style.
    """
    return [
        make_case(1.0, 0.0,  DEFAULT_MU, BANGLE_MESH_SIZE),
        make_case(1.0, 10.0, DEFAULT_MU, BANGLE_MESH_SIZE),
        make_case(1.0, 45.0, DEFAULT_MU, BANGLE_MESH_SIZE),
        make_case(1.0, 90.0, DEFAULT_MU, BANGLE_MESH_SIZE),
    ]


TEST_CASES = [make_case(1.0, 45.0, DEFAULT_MU, BANGLE_MESH_SIZE)]

if CASE_MODE == "full25":
    CASES = make_full25_cases()
elif CASE_MODE == "test4":
    CASES = make_test4_cases()
else:
    CASES = TEST_CASES


# ============================================================
# 2. GEOMETRIC AND PHYSICAL FUNCTIONS
# ============================================================

def drop_height_to_velocity(h_m):
    """
    Convert drop height h in meter to initial velocity in mm/s:
        v = sqrt(2 g h)
    """
    h_mm = h_m * 1000.0
    return math.sqrt(2.0 * G_MM * h_mm)


def compute_bangle_center_z(theta_deg):
    """
    Closed-form placement formula.

    The torus has:
        centerline radius R = MAJOR_RADIUS
        tube radius r = TUBE_RADIUS

    After tilt angle theta relative to the horizontal plane:
        lowest z relative to bangle center = -R*abs(sin(theta)) - r

    To keep the lowest point INITIAL_GAP above ground z=0:
        z_center = INITIAL_GAP + R*abs(sin(theta)) + r

    This avoids initial contact penetration.
    """
    theta_rad = math.radians(theta_deg)
    z_center = INITIAL_GAP + MAJOR_RADIUS * abs(math.sin(theta_rad)) + TUBE_RADIUS
    return z_center


def combined_rotation_angle(theta_deg):
    """
    The torus is created by revolving around the sketch vertical axis.
    Its initial torus axis is the global Y axis.
    A rotation of +90 deg around X changes the torus plane to the global X-Y plane.
    Then theta_deg is added to create the drop attitude.
    """
    return 90.0 + theta_deg


def print_case_info(case, v0, z_center):
    theta = case["theta_deg"]
    z_min_est = z_center - (MAJOR_RADIUS * abs(math.sin(math.radians(theta))) + TUBE_RADIUS)

    print("")
    print("============================================================")
    print("Building case: %s" % case["case_id"])
    print("  h_m          = %.4f m" % case["h_m"])
    print("  theta_deg    = %.2f deg" % case["theta_deg"])
    print("  mu           = %.3f" % case["mu"])
    print("  v0           = %.3f mm/s" % v0)
    print("  gravity      = %s, comp3 = %.1f mm/s^2" % (str(USE_GRAVITY), -G_MM))
    print("  z_center     = %.3f mm" % z_center)
    print("  estimated gap= %.6f mm" % z_min_est)
    print("============================================================")


# ============================================================
# 3. MODEL BUILDING FUNCTIONS
# ============================================================

def clear_default_models():
    """
    Do not delete Abaqus default Model-1 directly.

    In some Abaqus/CAE sessions, deleting the last/default model from
    mdb.models may raise:
        KeyError: Model-1

    The parametric cases are created with their own names later.
    Old parametric case models/jobs are safely removed in build_one_case().
    Therefore, this function only tries to remove non-default leftover models
    and keeps Model-1 as a harmless empty default model.
    """
    for name in list(mdb.models.keys()):
        if name == "Model-1":
            continue
        try:
            del mdb.models[name]
        except Exception:
            pass


def create_bangle_part(model):
    """
    Create a torus-shaped bangle by solid revolve.
    Inner diameter = 55 mm, tube diameter = 10 mm.
    """
    s = model.ConstrainedSketch(name="Bangle_Profile", sheetSize=200.0)

    # Axis of revolution. The circle must stay on one side of this construction line.
    s.ConstructionLine(point1=(0.0, -100.0), point2=(0.0, 100.0))

    # Circular tube cross-section.
    s.CircleByCenterPerimeter(
        center=(MAJOR_RADIUS, 0.0),
        point1=(MAJOR_RADIUS + TUBE_RADIUS, 0.0)
    )

    p = model.Part(
        name="Bangle",
        dimensionality=THREE_D,
        type=DEFORMABLE_BODY
    )
    p.BaseSolidRevolve(
        sketch=s,
        angle=360.0,
        flipRevolveDirection=OFF
    )

    del model.sketches["Bangle_Profile"]

    # All-cell set for material and velocity assignment.
    p.Set(cells=p.cells[:], name="BANGLE_ALL")

    return p


def create_ground_part(model):
    """
    Create a square discrete rigid ground surface in the global X-Y plane.
    Ground surface is located at z=0.
    """
    half = GROUND_SIZE / 2.0
    s = model.ConstrainedSketch(name="Ground_Profile", sheetSize=GROUND_SIZE * 1.5)
    s.rectangle(point1=(-half, -half), point2=(half, half))

    p = model.Part(
        name="Ground",
        dimensionality=THREE_D,
        type=DISCRETE_RIGID_SURFACE
    )
    p.BaseShell(sketch=s)
    del model.sketches["Ground_Profile"]

    # Reference point for rigid ground. This point will be fixed.
    p.ReferencePoint(point=(0.0, 0.0, 0.0))

    return p


def assign_material_and_section(model, bangle_part):
    mat = model.Material(name="Jade")
    mat.Density(table=((RHO_JADE,),))
    mat.Elastic(table=((E_JADE, NU_JADE),))

    model.HomogeneousSolidSection(
        name="Jade_Section",
        material="Jade",
        thickness=None
    )

    region = regionToolset.Region(cells=bangle_part.cells[:])
    bangle_part.SectionAssignment(
        region=region,
        sectionName="Jade_Section",
        offset=0.0,
        offsetType=MIDDLE_SURFACE,
        offsetField="",
        thicknessAssignment=FROM_SECTION
    )


def mesh_bangle_part(bangle_part, mesh_size):
    bangle_part.seedPart(
        size=mesh_size,
        deviationFactor=0.1,
        minSizeFactor=0.1
    )

    cells = bangle_part.cells[:]

    if BANGLE_ELEMENT.upper() == "TET4":
        bangle_part.setMeshControls(
            regions=cells,
            elemShape=TET,
            technique=FREE
        )
        elem1 = mesh.ElemType(elemCode=C3D4, elemLibrary=EXPLICIT)
        bangle_part.setElementType(regions=(cells,), elemTypes=(elem1,))
    else:
        bangle_part.setMeshControls(
            regions=cells,
            elemShape=TET,
            technique=FREE
        )
        elem1 = mesh.ElemType(elemCode=C3D10M, elemLibrary=EXPLICIT)
        elem2 = mesh.ElemType(elemCode=C3D4, elemLibrary=EXPLICIT)
        bangle_part.setElementType(regions=(cells,), elemTypes=(elem1, elem2))

    bangle_part.generateMesh()


def mesh_ground_part(ground_part):
    ground_part.seedPart(
        size=GROUND_MESH_SIZE,
        deviationFactor=0.1,
        minSizeFactor=0.1
    )

    faces = ground_part.faces[:]
    elem1 = mesh.ElemType(elemCode=R3D4, elemLibrary=EXPLICIT)
    elem2 = mesh.ElemType(elemCode=R3D3, elemLibrary=EXPLICIT)
    ground_part.setElementType(regions=(faces,), elemTypes=(elem1, elem2))

    ground_part.generateMesh()


def create_assembly(model, bangle_part, ground_part, theta_deg):
    a = model.rootAssembly
    a.DatumCsysByDefault(CARTESIAN)

    a.Instance(name="Bangle-1", part=bangle_part, dependent=ON)
    a.Instance(name="Ground-1", part=ground_part, dependent=ON)

    # 1. Rotate first.
    rot_angle = combined_rotation_angle(theta_deg)
    a.rotate(
        instanceList=("Bangle-1",),
        axisPoint=(0.0, 0.0, 0.0),
        axisDirection=(1.0, 0.0, 0.0),
        angle=rot_angle
    )

    # 2. Then translate by geometric formula, no bounding-box/manual movement.
    z_center = compute_bangle_center_z(theta_deg)
    a.translate(
        instanceList=("Bangle-1",),
        vector=(0.0, 0.0, z_center)
    )

    a.regenerate()

    return a, z_center


def create_step_and_outputs(model):
    model.ExplicitDynamicsStep(
        name="Step-1",
        previous="Initial",
        timePeriod=STEP_TIME,
        improvedDtMethod=ON
    )

    # Main output. Max principal stress can be checked from S invariants in Visualization.
    model.fieldOutputRequests["F-Output-1"].setValues(
        variables=("S", "E", "U", "V", "A", "STATUS"),
        numIntervals=NUM_INTERVALS
    )

    # Contact output for General Contact.
    # If your Abaqus version reports an invalid contact variable, remove F-Contact.
    model.FieldOutputRequest(
        name="F-Contact",
        createStepName="Step-1",
        variables=("CSTRESS", "CDISP", "CFORCE"),
        numIntervals=NUM_INTERVALS
    )

    model.historyOutputRequests["H-Output-1"].setValues(
        variables=("ALLAE", "ALLIE", "ALLKE", "ALLSE", "ETOTAL", "ALLWK"),
        numIntervals=NUM_INTERVALS
    )


def create_contact(model, mu):
    model.ContactProperty("Ground_Bangle_Contact")
    model.interactionProperties["Ground_Bangle_Contact"].TangentialBehavior(
        formulation=PENALTY,
        directionality=ISOTROPIC,
        slipRateDependency=OFF,
        pressureDependency=OFF,
        temperatureDependency=OFF,
        dependencies=0,
        table=((mu,),),
        shearStressLimit=None,
        maximumElasticSlip=FRACTION,
        fraction=0.005,
        elasticSlipStiffness=None
    )
    model.interactionProperties["Ground_Bangle_Contact"].NormalBehavior(
        pressureOverclosure=HARD,
        allowSeparation=ON,
        constraintEnforcementMethod=DEFAULT
    )

    # General contact is used to avoid surface-picking errors.
    model.ContactExp(name="General_Contact", createStepName="Initial")
    model.interactions["General_Contact"].includedPairs.setValuesInStep(
        stepName="Initial",
        useAllstar=ON
    )
    model.interactions["General_Contact"].contactPropertyAssignments.appendInStep(
        stepName="Initial",
        assignments=((GLOBAL, SELF, "Ground_Bangle_Contact"),)
    )


def apply_ground_boundary(model, assembly):
    ground_inst = assembly.instances["Ground-1"]
    rp_keys = list(ground_inst.referencePoints.keys())
    if len(rp_keys) == 0:
        raise RuntimeError("Ground reference point was not found.")

    rp = ground_inst.referencePoints[rp_keys[0]]
    rp_region = regionToolset.Region(referencePoints=(rp,))

    model.EncastreBC(
        name="Fix_Ground_RP",
        createStepName="Initial",
        region=rp_region,
        localCsys=None
    )


def apply_initial_velocity_and_gravity(model, assembly, v0):
    bangle_region = regionToolset.Region(cells=assembly.instances["Bangle-1"].cells[:])

    model.Velocity(
        name="Initial_Drop_Velocity",
        region=bangle_region,
        field="",
        distributionType=MAGNITUDE,
        velocity1=0.0,
        velocity2=0.0,
        velocity3=-v0,
        omega=0.0
    )

    if USE_GRAVITY:
        model.Gravity(
            name="Gravity",
            createStepName="Step-1",
            comp3=-G_MM,
            distributionType=UNIFORM,
            field=""
        )


def create_job(model_name, job_name):
    mdb.Job(
        name=job_name,
        model=model_name,
        description="Parametric jade bangle drop-impact model",
        type=ANALYSIS,
        atTime=None,
        waitMinutes=0,
        waitHours=0,
        queue=None,
        memory=90,
        memoryUnits=PERCENTAGE,
        explicitPrecision=SINGLE,
        nodalOutputPrecision=SINGLE,
        echoPrint=OFF,
        modelPrint=OFF,
        contactPrint=OFF,
        historyPrint=OFF,
        userSubroutine="",
        scratch="",
        resultsFormat=ODB,
        parallelizationMethodExplicit=DOMAIN,
        numDomains=NUM_DOMAINS,
        activateLoadBalancing=False,
        numThreadsPerMpiProcess=1,
        multiprocessingMode=DEFAULT,
        numCpus=NUM_CPUS
    )


def build_one_case(case):
    model_name = case["case_id"]
    job_name = case["case_id"]

    if model_name in mdb.models.keys():
        del mdb.models[model_name]
    if job_name in mdb.jobs.keys():
        del mdb.jobs[job_name]

    model = mdb.Model(name=model_name)

    # Compute the initial velocity from the assumed drop height H.
    # The actual predefined velocity is velocity3 = -v0.
    v0 = drop_height_to_velocity(case["h_m"])
    z_center = compute_bangle_center_z(case["theta_deg"])
    print_case_info(case, v0, z_center)

    bangle_part = create_bangle_part(model)
    ground_part = create_ground_part(model)

    assign_material_and_section(model, bangle_part)

    mesh_bangle_part(bangle_part, case["mesh_size"])
    mesh_ground_part(ground_part)

    assembly, z_center = create_assembly(
        model=model,
        bangle_part=bangle_part,
        ground_part=ground_part,
        theta_deg=case["theta_deg"]
    )

    create_step_and_outputs(model)
    create_contact(model, case["mu"])
    apply_ground_boundary(model, assembly)
    apply_initial_velocity_and_gravity(model, assembly, v0)

    create_job(model_name, job_name)
    return job_name


def submit_jobs_in_batches(job_names):
    """
    Submit jobs in groups. With NUM_CPUS = 3 and MAX_PARALLEL_JOBS = 4,
    at most four jobs are submitted at the same time.
    """
    if not SUBMIT_JOBS:
        return

    for start in range(0, len(job_names), MAX_PARALLEL_JOBS):
        batch = job_names[start:start + MAX_PARALLEL_JOBS]
        print("")
        print("Submitting batch: %s" % ", ".join(batch))

        for job_name in batch:
            mdb.jobs[job_name].submit(consistencyChecking=OFF)

        if WAIT_FOR_BATCH_COMPLETION:
            for job_name in batch:
                mdb.jobs[job_name].waitForCompletion()
            print("Batch completed: %s" % ", ".join(batch))


# ============================================================
# 4. MAIN
# ============================================================

def main():
    if not os.path.isdir(WORK_DIR):
        os.makedirs(WORK_DIR)
    os.chdir(WORK_DIR)

    clear_default_models()

    built_jobs = []
    for case in CASES:
        job_name = build_one_case(case)
        built_jobs.append(job_name)

    mdb.saveAs(pathName=os.path.join(WORK_DIR, CAE_NAME))

    print("")
    print("Finished building models and jobs.")
    print("CAE saved to: %s" % os.path.join(WORK_DIR, CAE_NAME))
    print("Number of built cases: %d" % len(CASES))
    print("Job names:")
    for job_name in built_jobs:
        print("  %s" % job_name)
    print("NUM_CPUS per job    = %d" % NUM_CPUS)
    print("NUM_DOMAINS per job = %d" % NUM_DOMAINS)
    print("MAX_PARALLEL_JOBS   = %d" % MAX_PARALLEL_JOBS)
    print("SUBMIT_JOBS         = %s" % str(SUBMIT_JOBS))
    print("Velocity rule       = v0 = sqrt(2 * G_MM * h_mm), applied as velocity3 = -v0")

    submit_jobs_in_batches(built_jobs)


main()
